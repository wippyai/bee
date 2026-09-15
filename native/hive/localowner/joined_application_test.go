//go:build meshclient

// SPDX-License-Identifier: MIT

package localowner

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/wippyai/bee/native/client/mesh"
	machineconfig "github.com/wippyai/bee/native/hive/config"
	"github.com/wippyai/bee/native/hive/rendezvous"
	"github.com/wippyai/runtime/api/boot"
	topapi "github.com/wippyai/runtime/api/topology"
	stackpkg "github.com/wippyai/runtime/cluster"
)

type joinedConnectivityProbe struct{ report string }

func (p *joinedConnectivityProbe) Name() string        { return "bee.test.joined_connectivity" }
func (p *joinedConnectivityProbe) DependsOn() []string { return []string{"cluster"} }
func (p *joinedConnectivityProbe) Load(ctx context.Context) (context.Context, error) {
	return ctx, nil
}
func (p *joinedConnectivityProbe) Start(ctx context.Context) error {
	registry := topapi.GetEventualRegistry(ctx)
	if registry == nil {
		return errors.New("joined connectivity probe requires eventual registry")
	}
	go func() {
		ticker := time.NewTicker(20 * time.Millisecond)
		defer ticker.Stop()
		for {
			found, err := registry.Lookup(ctx, "bee.proof/sender/seed-proof")
			if err == nil && found.Found && found.PID.Node == "seed-proof" {
				_ = os.WriteFile(p.report, []byte(found.PID.Node), 0o600)
				return
			}
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	}()
	return nil
}

var _ boot.Component = (*joinedConnectivityProbe)(nil)
var _ boot.Starter = (*joinedConnectivityProbe)(nil)

type joinedOwnerProcess struct {
	cancel context.CancelFunc
	done   chan struct{}
	once   sync.Once
	err    error
	output lockedBuffer
}

type lockedBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (b *lockedBuffer) Write(data []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.b.Write(data)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.b.String()
}

func startJoinedOwner(t *testing.T, parent context.Context, state, configuration, report string) *joinedOwnerProcess {
	t.Helper()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(parent)
	process := &joinedOwnerProcess{cancel: cancel, done: make(chan struct{})}
	command := exec.CommandContext(ctx, executable, "-test.run=^TestLocalOwnerApplicationSubprocess$")
	command.Env = append(os.Environ(), "BEE_OWNER_TEST_STATE="+state, "BEE_OWNER_TEST_CONFIG="+configuration, "BEE_OWNER_TEST_LIFETIME=30s")
	if report != "" {
		command.Env = append(command.Env, "BEE_OWNER_TEST_CONNECTIVITY_REPORT="+report)
	}
	command.Stdout, command.Stderr = &process.output, &process.output
	if err := command.Start(); err != nil {
		cancel()
		t.Fatal(err)
	}
	go func() {
		process.err = command.Wait()
		close(process.done)
	}()
	t.Cleanup(process.stop)
	return process
}

func (p *joinedOwnerProcess) stop() {
	p.once.Do(func() {
		p.cancel()
		select {
		case <-p.done:
		case <-time.After(5 * time.Second):
		}
	})
}

func (p *joinedOwnerProcess) waitDescriptor(ctx context.Context, directory, previousExecution string) (rendezvous.Descriptor, error) {
	store, err := rendezvous.New(directory)
	if err != nil {
		return rendezvous.Descriptor{}, err
	}
	for {
		descriptor, readErr := store.Read(ctx)
		if readErr == nil && descriptor.Execution != previousExecution {
			return descriptor, nil
		}
		if readErr != nil && !errors.Is(readErr, os.ErrNotExist) {
			return rendezvous.Descriptor{}, readErr
		}
		select {
		case <-p.done:
			return rendezvous.Descriptor{}, errors.New("owner exited before publishing rendezvous: " + p.output.String())
		case <-ctx.Done():
			return rendezvous.Descriptor{}, ctx.Err()
		case <-time.After(20 * time.Millisecond):
		}
	}
}

func fourFreePorts(t *testing.T) [4]uint16 {
	t.Helper()
	var listeners [4]net.Listener
	var ports [4]uint16
	for index := range listeners {
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		listeners[index] = listener
		ports[index] = uint16(listener.Addr().(*net.TCPAddr).Port)
	}
	for _, listener := range listeners {
		_ = listener.Close()
	}
	return ports
}

func saveJoinedProfile(t *testing.T, directory, node string, private ed25519.PrivateKey, peers map[string]string, secret []byte, seed string, membershipPort, internodePort uint16, certPath, keyPath, caPath string) {
	t.Helper()
	store, err := machineconfig.New(directory)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Update(context.Background(), 0, func(document machineconfig.Document) (machineconfig.Document, error) {
		document.Hive = machineconfig.HiveProfile{
			Mode: machineconfig.HiveModeJoined, HiveID: "persisted-proof", NodeID: node,
			Seeds: []string{seed}, MembershipSecret: machineconfig.Secret(base64.StdEncoding.EncodeToString(secret)),
			InternodePrivateKey: machineconfig.Secret(base64.StdEncoding.EncodeToString(private)), PeerPublicKeys: peers,
			TLSCertPath: certPath, TLSKeyPath: keyPath, TLSCAPath: caPath,
			MembershipBindAddress: "127.0.0.1", MembershipBindPort: membershipPort,
			MembershipAdvertiseAddress: "127.0.0.1", MembershipAdvertisePort: membershipPort,
			InternodeBindAddress: "127.0.0.1", InternodeBindPort: internodePort,
			InternodeAdvertiseAddress: "127.0.0.1", InternodeAdvertisePort: internodePort,
		}
		return document, nil
	}); err != nil {
		t.Fatal(err)
	}
}

func TestPersistedJoinedOwnersConvergeAfterLateSeedAndRestart(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Second)
	defer cancel()
	ports := fourFreePorts(t)
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		t.Fatal(err)
	}
	seedPublic, seedPrivate, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	joinerPublic, joinerPrivate, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	peers := map[string]string{
		"seed-proof":   base64.StdEncoding.EncodeToString(seedPublic),
		"joiner-proof": base64.StdEncoding.EncodeToString(joinerPublic),
	}
	certPath, keyPath, caPath := joinedProfileTLS(t)
	seedConfig, joinerConfig := privateDirectory(t), privateDirectory(t)
	seedState, joinerState := filepath.Join(t.TempDir(), "seed-state"), filepath.Join(t.TempDir(), "joiner-state")
	seedAddress := net.JoinHostPort("127.0.0.1", strconv.Itoa(int(ports[0])))
	saveJoinedProfile(t, seedConfig, "seed-proof", seedPrivate, peers, secret, "127.0.0.1:1", ports[0], ports[1], certPath, keyPath, caPath)
	saveJoinedProfile(t, joinerConfig, "joiner-proof", joinerPrivate, peers, secret, seedAddress, ports[2], ports[3], certPath, keyPath, caPath)

	started := time.Now()
	connectivityReport := filepath.Join(t.TempDir(), "connected")
	joiner := startJoinedOwner(t, ctx, joinerState, joinerConfig, connectivityReport)
	joinerDirectory := filepath.Join(joinerState, DirectoryName)
	first, err := joiner.waitDescriptor(ctx, joinerDirectory, "")
	if err != nil {
		t.Fatal(err)
	}
	if elapsed := time.Since(started); elapsed >= 8*time.Second {
		t.Fatalf("joiner waited for absent seed: %s", elapsed)
	}
	seed := startJoinedOwner(t, ctx, seedState, seedConfig, "")
	if _, err := seed.waitDescriptor(ctx, filepath.Join(seedState, DirectoryName), ""); err != nil {
		t.Fatal(err)
	}
	awaitSeed := func() error {
		return mesh.SameAccount(ctx, joinerDirectory, func(frame context.Context, stack *stackpkg.Stack, _ rendezvous.Descriptor) error {
			ticker := time.NewTicker(20 * time.Millisecond)
			defer ticker.Stop()
			for {
				member := false
				for _, node := range stack.Membership.Nodes() {
					member = member || node.ID == "seed-proof"
				}
				if member {
					return nil
				}
				select {
				case <-frame.Done():
					return frame.Err()
				case <-ticker.C:
				}
			}
		})
	}
	if err := awaitSeed(); err != nil {
		t.Fatalf("late seed did not converge: %v\njoiner: %s\nseed: %s", err, joiner.output.String(), seed.output.String())
	}
	if err := waitReport(ctx, connectivityReport, "seed-proof"); err != nil {
		t.Fatalf("joined owners lacked internode registry propagation: %v\njoiner: %s\nseed: %s", err, joiner.output.String(), seed.output.String())
	}
	joiner.stop()
	if err := os.Remove(connectivityReport); err != nil {
		t.Fatal(err)
	}
	restarted := startJoinedOwner(t, ctx, joinerState, joinerConfig, connectivityReport)
	second, err := restarted.waitDescriptor(ctx, joinerDirectory, first.Execution)
	if err != nil {
		t.Fatal(err)
	}
	if second.Node != first.Node || second.PublicKey != first.PublicKey {
		t.Fatalf("saved joined identity changed across restart: before=%#v after=%#v", first, second)
	}
	if err := awaitSeed(); err != nil {
		t.Fatalf("restarted joiner did not reconnect: %v\njoiner: %s\nseed: %s", err, restarted.output.String(), seed.output.String())
	}
	if err := waitReport(ctx, connectivityReport, "seed-proof"); err != nil {
		t.Fatalf("restarted owner lacked internode registry propagation: %v\njoiner: %s\nseed: %s", err, restarted.output.String(), seed.output.String())
	}
}

func waitReport(ctx context.Context, path, expected string) error {
	for {
		data, err := os.ReadFile(path)
		if err == nil && string(data) == expected {
			return nil
		}
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(20 * time.Millisecond):
		}
	}
}
