//go:build meshclient

// SPDX-License-Identifier: MIT
package localowner

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	hiveclient "github.com/wippyai/bee/native/client/hive"
	"github.com/wippyai/bee/native/client/mesh"
	"github.com/wippyai/bee/native/hive/localtls"
	"github.com/wippyai/bee/native/hive/rendezvous"
	"github.com/wippyai/runtime/api/boot"
	topapi "github.com/wippyai/runtime/api/topology"
	stackpkg "github.com/wippyai/runtime/cluster"
	app "github.com/wippyai/runtime/cmd/app"
	"github.com/wippyai/wapp"
)

type testLauncher struct{ *Component }

func (c testLauncher) Launch(ctx context.Context, request app.LaunchRequest, runOwner func(app.OwnerOptions) error) error {
	return runOwner(app.OwnerOptions{Prepare: func(context.Context) (app.OwnerResources, error) {
		return c.PrepareOwner(ctx, request)
	}})
}

func TestRuntimeOwnerRunnerKeepsOneNativePreparationAtATime(t *testing.T) {
	state := t.TempDir()
	started := make(chan struct{})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	options := app.Options{
		Name: "native-owner-lock", Mode: "base", Command: "owner",
		Launch: func(_ context.Context, _ app.LaunchRequest, runOwner func(app.OwnerOptions) error) error {
			return runOwner(app.OwnerOptions{Prepare: func(ctx context.Context) (app.OwnerResources, error) {
				close(started)
				<-ctx.Done()
				return app.OwnerResources{}, ctx.Err()
			}})
		},
	}
	first := make(chan error, 1)
	go func() { first <- app.Run(ctx, options, []string{"--state-dir", state}) }()
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("first owner never entered preparation")
	}
	err := app.Run(context.Background(), options, []string{"--state-dir", state})
	if !errors.Is(err, app.ErrBusy) {
		t.Fatalf("second owner did not receive runtime contention: %v", err)
	}
	cancel()
	if err := <-first; !errors.Is(err, context.Canceled) {
		t.Fatalf("first owner cleanup: %v", err)
	}
	err = app.Run(context.Background(), app.Options{
		Name: "native-owner-lock", Mode: "base", Command: "owner",
		Launch: func(_ context.Context, _ app.LaunchRequest, runOwner func(app.OwnerOptions) error) error {
			return runOwner(app.OwnerOptions{})
		},
	}, []string{"--state-dir", state})
	if errors.Is(err, app.ErrBusy) {
		t.Fatalf("runtime retained owner exclusion after cleanup: %v", err)
	}
}

func TestNormalApplicationBootAdmitsNativeTransportAndExpires(t *testing.T) {
	state := filepath.Join(t.TempDir(), "state")
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, executable, "-test.run=^TestLocalOwnerApplicationSubprocess$")
	command.Env = append(os.Environ(), "BEE_OWNER_TEST_STATE="+state)
	var output bytes.Buffer
	command.Stdout, command.Stderr = &output, &output
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	exited := make(chan struct{})
	var exitError error
	go func() { exitError = command.Wait(); close(exited) }()
	t.Cleanup(func() { _ = command.Process.Kill(); <-exited })
	store, err := rendezvous.New(filepath.Join(state, DirectoryName))
	if err != nil {
		t.Fatal(err)
	}
	ticker := time.NewTicker(20 * time.Millisecond)
	defer ticker.Stop()
	var descriptor rendezvous.Descriptor
	for {
		descriptor, err = store.Read(ctx)
		if err == nil {
			break
		}
		if !errors.Is(err, os.ErrNotExist) {
			t.Fatal(err)
		}
		select {
		case <-exited:
			t.Fatalf("owner exited before discovery: %v\n%s", exitError, output.String())
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		case <-ticker.C:
		}
	}
	credentials, err := localtls.Load(ctx, filepath.Join(state, DirectoryName), descriptor.Execution)
	if err != nil {
		t.Fatal(err)
	}
	expires := time.NewTimer(time.Until(credentials.ExpiresAt.Add(2 * time.Second)))
	defer expires.Stop()
	err = mesh.SameAccount(ctx, filepath.Join(state, DirectoryName), func(clientContext context.Context, stack *stackpkg.Stack, actual rendezvous.Descriptor) error {
		if actual != descriptor {
			return errors.New("owner descriptor changed during native connection")
		}
		if stack.Node.ID() == descriptor.Node {
			return errors.New("client reused owner identity")
		}
		return mesh.WithActor(clientContext, stack, descriptor.Node, func(frame context.Context, actor *mesh.Actor) error {
			names := topapi.GetEventualRegistry(frame)
			if names == nil {
				return errors.New("native naming unavailable")
			}
			lookup := time.NewTicker(20 * time.Millisecond)
			defer lookup.Stop()
			for {
				found, lookupError := names.Lookup(frame, "bee.proof/sender")
				if lookupError == nil && found.Found {
					request, err := json.Marshal(map[string]string{"request_id": "sender-proof", "expected_peer": actor.PID().Node})
					if err != nil {
						return err
					}
					if err := actor.Send(frame, found.PID, "bee.proof.request", request); err != nil {
						return err
					}
					reply, err := actor.Receive(frame)
					if err != nil {
						return fmt.Errorf("receive Lua sender proof: %w", err)
					}
					if reply.From.Node != found.PID.Node || reply.From.Host != found.PID.Host || reply.From.UniqID != found.PID.UniqID || reply.Topic != "bee.proof.reply" {
						return fmt.Errorf("native Lua reply provenance mismatch: from=%v want=%v topic=%q", reply.From, found.PID, reply.Topic)
					}
					var body struct {
						RequestID string `json:"request_id"`
						Peer      string `json:"peer"`
						Verified  bool   `json:"verified"`
					}
					decoder := json.NewDecoder(bytes.NewReader(reply.Body))
					decoder.DisallowUnknownFields()
					if err := decoder.Decode(&body); err != nil {
						return err
					}
					if body.RequestID != "sender-proof" || body.Peer != actor.PID().Node || !body.Verified {
						return errors.New("Lua did not observe the expected native sender")
					}
					control, err := hiveclient.New(frame, actor, descriptor.Node)
					if err != nil {
						return err
					}
					for {
						if _, err := actor.OwnerSupervisor(frame); err == nil {
							break
						}
						select {
						case <-frame.Done():
							return frame.Err()
						case <-lookup.C:
						}
					}
					input, err := json.Marshal(map[string]string{"expected_peer": actor.PID().Node})
					if err != nil {
						return err
					}
					operation := hiveclient.Operation{Owner: hiveclient.Owner{Node: descriptor.Node, Service: "bee.proof"}, Ref: "bee.proof:call", Key: "native-wire-proof", Input: input}
					accepted, err := control.Call(frame, operation)
					if err != nil {
						return fmt.Errorf("native Hive call: %w", err)
					}
					if !accepted.OK || accepted.Done() == nil {
						return errors.New("native Hive success lacked caller lifetime")
					}
					var verified struct {
						Peer string `json:"peer"`
					}
					if err := json.Unmarshal(accepted.Value, &verified); err != nil || verified.Peer != actor.PID().Node {
						return errors.New("native Hive result did not retain verified peer")
					}
					operation.Key = "native-wire-denial"
					denied, err := control.Call(frame, operation)
					if err != nil || denied.OK || denied.Fault == nil || denied.Fault.Code != "DENIED" {
						return fmt.Errorf("native Hive typed denial missing: %v", err)
					}
					return nil
				}
				select {
				case <-frame.Done():
					return frame.Err()
				case <-lookup.C:
				}
			}
		})
	})
	if err != nil {
		_ = command.Process.Kill()
		<-exited
		t.Fatalf("native Lua exchange failed: %v\nowner exit: %v\n%s", err, exitError, output.String())
	}
	// Credential expiry cuts off transport first. The intentionally sleeping
	// Lua fixture does not consume CANCEL, so normal host cleanup may use its
	// configured ten-second graceful-stop period. The owner must retain its
	// application lock throughout that drain rather than claim completion early.
	select {
	case <-exited:
	case <-expires.C:
		connection, dialError := net.DialTimeout("tcp", descriptor.Transport, 200*time.Millisecond)
		if connection != nil {
			_ = connection.Close()
		}
		if dialError == nil {
			t.Fatal("owner mesh survived credential expiry")
		}
		cleanup := time.NewTimer(time.Until(credentials.ExpiresAt.Add(15 * time.Second)))
		defer cleanup.Stop()
		select {
		case <-exited:
		case <-cleanup.C:
			t.Fatal("owner exceeded bounded process cleanup after credential expiry")
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		}
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	if exitError != nil {
		t.Fatalf("owner failed: %v\n%s", exitError, output.String())
	}
	listener, err := net.Listen("tcp", descriptor.Transport)
	if err != nil {
		t.Fatalf("owner shutdown retained native listener: %v", err)
	}
	_ = listener.Close()
}

func TestLocalOwnerApplicationSubprocess(t *testing.T) {
	state := os.Getenv("BEE_OWNER_TEST_STATE")
	if state == "" {
		t.Skip("subprocess helper")
	}
	owner, err := New(Options{Node: "owner-proof", Lifetime: 8 * time.Second})
	if err != nil {
		t.Fatal(err)
	}
	entries := []wapp.Entry{
		{ID: wapp.NewID("bee.proof", "definition"), Kind: "ns.definition"},
		{ID: wapp.NewID("bee.proof", "terminal"), Kind: "terminal.host", Data: map[string]any{"hide_logs": true, "lifecycle": map[string]any{"auto_start": true}}},
		{ID: wapp.NewID("bee.proof", "name_policy"), Kind: "security.policy", Data: map[string]any{
			"policy": map[string]any{"actions": []string{"process.registry.register.eventual"}, "resources": []string{"bee.proof/sender", "bee.hive.supervisor/owner-proof"}, "effect": "allow"},
		}},
		{ID: wapp.NewID("bee.proof", "reply_policy"), Kind: "security.policy", Data: map[string]any{
			"policy": map[string]any{"actions": []string{"process.send"}, "resources": []string{"*"}, "effect": "allow"},
		}},
		// A native process service exercises the existing Hive wire envelope.
		// It issues no production admission or viewport grant.
		{ID: wapp.NewID("bee.hive", "supervisor_host"), Kind: "process.host", Data: map[string]any{
			"host": map[string]any{"workers": 1, "max_processes": 4}, "lifecycle": map[string]any{"auto_start": true},
		}},
		{ID: wapp.NewID("bee.proof", "hive_service"), Kind: "process.service", Data: map[string]any{
			"process": "bee.proof:hive", "host": "bee.hive:supervisor_host",
			"lifecycle": map[string]any{"auto_start": true, "security": map[string]any{
				"actor": map[string]any{"id": "bee.proof.hive"}, "policies": []string{"bee.proof:name_policy", "bee.proof:reply_policy"},
			}},
		}},
		{ID: wapp.NewID("bee.proof", "hive"), Kind: "process.lua", Data: map[string]any{
			"source": `local process = require("process")
local time = require("time")
local function main()
    local inbox, err = process.listen("bee.hive.request", {message = true})
    if not inbox then error(tostring(err)) end
    assert(process.registry.register("bee.hive.supervisor/owner-proof", nil, process.registry.EVENTUAL))
    for index = 1, 2 do
        local message = inbox:receive()
        assert(message)
        local peer = tostring(message:from()):match("^{([^@|}]*)@")
        assert(peer and peer ~= "")
        local call = message:payload():data()
        assert(call.protocol_revision == "bee.hive@1" and call.owner_ref.node_id == "owner-proof"
            and call.owner_ref.service_id == "bee.proof" and call.target.operation_ref == "bee.proof:call"
            and call.input.expected_peer == peer and type(call.deadline) == "string")
        if index == 1 then
            assert(process.send(message:from(), "bee.hive.reply", {protocol_revision = "bee.hive@1", request_id = call.request_id,
                ok = true, value = {peer = peer}, grants = {}}))
        else
            assert(process.send(message:from(), "bee.hive.reply", {protocol_revision = "bee.hive@1", request_id = call.request_id,
                ok = false, error = {code = "DENIED", message = "fixture denial", retryable = false}, grants = {}}))
        end
    end
    local events = assert(process.events())
    while true do
        local event = events:receive()
        if not event or event.kind == process.event.CANCEL then return end
    end
end
return {main = main}`,
			"method": "main", "modules": []string{"process", "time"},
		}},
		{ID: wapp.NewID("bee.proof", "main"), Kind: "process.lua", Data: map[string]any{
			"source": `local time = require("time")
local process = require("process")
local M = {}
function M.main()
    local registered, registration_error = process.registry.register("bee.proof/sender", nil, process.registry.EVENTUAL)
    if not registered then error(tostring(registration_error)) end
    local inbox, inbox_error = process.listen("bee.proof.request", {message = true})
    if not inbox then error(tostring(inbox_error)) end
    local message = inbox:receive()
    assert(message)
    local peer = tostring(message:from()):match("^{([^@|}]*)@")
    assert(peer and peer ~= "")
    local request = message:payload():data()
    assert(peer == request.expected_peer)
    local sent, send_error = process.send(message:from(), "bee.proof.reply", {request_id = request.request_id, peer = peer, verified = true})
    if not sent then error(tostring(send_error)) end
    time.sleep("30s")
    return 0
end
return M`,
			"method": "main", "modules": []string{"time", "process"},
			"security": map[string]any{"policies": []string{"bee.proof:name_policy", "bee.proof:reply_policy"}},
		}, Meta: wapp.Metadata{"command": map[string]any{"name": "owner-proof"}}},
	}
	var packed bytes.Buffer
	if err := wapp.NewWriter().PackEntries(wapp.Metadata{"namespace": "bee.proof", "name": "proof", "version": "1.0.0"}, entries, &packed); err != nil {
		t.Fatal(err)
	}
	data := packed.Bytes()
	bundle := app.Bundle{Root: "bee/proof", Packs: []app.Pack{{Module: "bee/proof", Version: "1.0.0", Digest: fmt.Sprintf("sha256:%x", sha256.Sum256(data)), Data: data}}}
	launcher := testLauncher{owner}
	err = app.Run(context.Background(), app.Options{Name: "bee-owner-proof", Mode: "base", Command: "owner-proof", Bundle: bundle, Launch: launcher.Launch, Components: []boot.Component{launcher}}, []string{"--state-dir", state})
	if err != nil && !errors.Is(err, context.DeadlineExceeded) && !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
}
