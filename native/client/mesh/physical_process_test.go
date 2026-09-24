//go:build meshclient && physicalclient && !windows

// SPDX-License-Identifier: MIT
package mesh

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/creack/pty"
	"github.com/wippyai/bee/native/client/physical"
	"github.com/wippyai/bee/native/hive/rendezvous"
	"github.com/wippyai/runtime/api/payload"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/api/relay"
	ttyapi "github.com/wippyai/runtime/api/tty"
	stackpkg "github.com/wippyai/runtime/cluster"
	"github.com/wippyai/runtime/cluster/internode"
)

// Files below coordinate only fixture-selected grants, not production admission.
// All display frames, typed keys and resizes travel through native mesh sockets.
func TestSeparatePhysicalClientsReattachToRetainedViewport(t *testing.T) {
	ownerTLS, clientTLS := clientTestTLSCerts(t, "owner", "client")
	ctx, dir, owner, _, _ := localOwnerTLS(t, ownerTLS)
	producer, viewport, _, events := ownerViewport(t, owner)
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	var previous pid.PID
	for range 2 {
		report := filepath.Join(t.TempDir(), "recipient")
		grant := filepath.Join(t.TempDir(), "grant")
		cmd := exec.CommandContext(ctx, executable, "-test.run=^TestPhysicalClientSubprocess$")
		cmd.Env = append(os.Environ(), "BEE_PHYSICAL_TEST_DISCOVERY="+dir, "BEE_PHYSICAL_TEST_RECIPIENT="+report, "BEE_PHYSICAL_TEST_GRANT="+grant, "BEE_PHYSICAL_TEST_TLS_CERT="+clientTLS.CertFile, "BEE_PHYSICAL_TEST_TLS_KEY="+clientTLS.KeyFile, "BEE_PHYSICAL_TEST_TLS_CA="+clientTLS.CAFile)
		terminal, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: 24, Cols: 80})
		if err != nil {
			t.Fatal(err)
		}
		exited := make(chan struct{})
		var childErr error
		go func() { childErr = cmd.Wait(); close(exited) }()
		t.Cleanup(func() { _ = cmd.Process.Kill(); terminal.Close(); <-exited })
		painted := make(chan struct{})
		readDone := make(chan error, 1)
		go func() {
			var output bytes.Buffer
			found := false
			buffer := make([]byte, 4096)
			for {
				n, err := terminal.Read(buffer)
				if output.Len()+n > 1<<20 {
					readDone <- errors.New("physical fixture output overflow")
					return
				}
				output.Write(buffer[:n])
				if !found && strings.Contains(output.String(), "RETAINED_ACTOR_VIEW") {
					found = true
					close(painted)
				}
				if err != nil {
					readDone <- err
					return
				}
			}
		}()
		data, err := waitFixtureFile(ctx, report)
		if err != nil {
			t.Fatal(err)
		}
		recipient, err := pid.ParsePID(string(data))
		if err != nil {
			t.Fatal(err)
		}
		if samePID(recipient, previous) {
			t.Fatal("reused physical client recipient")
		}
		previous = recipient
		proof := relay.NewPackage(pid.PID{Node: owner.Node.ID(), Host: "producer-fixture", UniqID: "retained"}, recipient, "bee.client.transport-proof", payload.NewPayload([]byte(`{"tls":true}`), payload.JSON))
		if err := owner.Router.SendContext(ctx, proof); err != nil {
			relay.ReleasePackage(proof)
			t.Fatal(err)
		}
		ref, err := viewport.(ttyapi.MountableViewport).Mount(producer, recipient, ttyapi.MountRights{Observe: true, Input: true, Resize: true})
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(grant, []byte(ref), 0600); err != nil {
			t.Fatal(err)
		}
		select {
		case <-painted:
		case err := <-readDone:
			t.Fatalf("client failed before paint: %v", err)
		case <-ctx.Done():
			t.Fatal("client never painted native viewport")
		}
		if _, err := terminal.Write([]byte("z")); err != nil {
			t.Fatal(err)
		}
	input:
		for {
			select {
			case event := <-events:
				if event.Type == "key" && event.Key == "z" {
					break input
				}
			case <-exited:
				t.Fatalf("client exited before key delivery: %v", childErr)
			case <-ctx.Done():
				t.Fatal("physical key did not reach owner")
			}
		}
		if _, err := terminal.Write([]byte{0x1d}); err != nil {
			t.Fatal(err)
		}
		select {
		case <-exited:
			if childErr != nil {
				t.Fatalf("client detach: %v", childErr)
			}
		case <-ctx.Done():
			t.Fatal("physical detach hung")
		}
		terminal.Close()
		<-readDone
		if snapshot := viewport.Snapshot(); len(snapshot.Rows) == 0 || snapshot.Rows[0] != "RETAINED_ACTOR_VIEW" {
			t.Fatal("client exit erased owner viewport")
		}
	}
}

func TestPhysicalClientSubprocess(t *testing.T) {
	dir := os.Getenv("BEE_PHYSICAL_TEST_DISCOVERY")
	if dir == "" {
		t.Skip("subprocess helper")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	err := joinFresh(ctx, dir, internode.ManagerTLSConfig{Enabled: true, CertFile: os.Getenv("BEE_PHYSICAL_TEST_TLS_CERT"), KeyFile: os.Getenv("BEE_PHYSICAL_TEST_TLS_KEY"), CAFile: os.Getenv("BEE_PHYSICAL_TEST_TLS_CA")}, func(ctx context.Context, stack *stackpkg.Stack, owner rendezvous.Descriptor) error {
		return WithActor(ctx, stack, owner.Node, func(frame context.Context, actor *Actor) error {
			recipient := actor.PID()
			if err := os.WriteFile(os.Getenv("BEE_PHYSICAL_TEST_RECIPIENT"), []byte(recipient.String()), 0600); err != nil {
				return err
			}
			proof, err := actor.Receive(frame)
			if err != nil {
				return err
			}
			if proof.Topic != "bee.client.transport-proof" || proof.From.Node != owner.Node {
				return errors.New("physical client did not receive owner-native sender")
			}
			grant, err := waitFixtureFile(frame, os.Getenv("BEE_PHYSICAL_TEST_GRANT"))
			if err != nil {
				return err
			}
			mounted, err := ttyapi.GetService(frame).Attach(frame, string(grant))
			if err != nil {
				return err
			}
			view, ok := mounted.(physical.Viewport)
			if !ok {
				mounted.Close()
				return errors.New("missing native checked viewport")
			}
			// The test ends the client with a local detach (Ctrl+]).
			if err := physical.Run(frame, view, ttyapi.MountRights{Observe: true, Input: true, Resize: true}, os.Stdin, os.Stdout); !errors.Is(err, physical.ErrDetached) {
				return err
			}
			return nil
		})
	})
	if err != nil {
		t.Fatal(err)
	}
}

func waitFixtureFile(ctx context.Context, path string) ([]byte, error) {
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	for {
		data, err := os.ReadFile(path)
		if err == nil && len(data) > 0 {
			return data, nil
		}
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-ticker.C:
		}
	}
}
