//go:build meshclient

// SPDX-License-Identifier: MIT
package mesh

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/wippyai/bee/native/hive/meshtls"
	"github.com/wippyai/bee/native/hive/rendezvous"
	"github.com/wippyai/runtime/api/boot"
	clusterapi "github.com/wippyai/runtime/api/cluster"
	metricscfg "github.com/wippyai/runtime/api/service/metrics"
	stackpkg "github.com/wippyai/runtime/cluster"
	"github.com/wippyai/runtime/cluster/internode"
	app "github.com/wippyai/runtime/cmd/app"
	"github.com/wippyai/runtime/service/metrics"
	"github.com/wippyai/runtime/system/eventbus"
	"github.com/wippyai/runtime/system/payload"
	"go.uber.org/zap"
)

func localOwner(t *testing.T) (context.Context, string, *stackpkg.Stack, *rendezvous.Enrollment, rendezvous.Descriptor) {
	return localOwnerTLS(t, internode.ManagerTLSConfig{})
}

func localOwnerTLS(t *testing.T, transport internode.ManagerTLSConfig) (context.Context, string, *stackpkg.Stack, *rendezvous.Enrollment, rendezvous.Descriptor) {
	return localOwnerTransport(t, transport, false)
}

func localOwnerTransport(t *testing.T, transport internode.ManagerTLSConfig, provision bool) (context.Context, string, *stackpkg.Stack, *rendezvous.Enrollment, rendezvous.Descriptor) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	t.Cleanup(cancel)
	state := t.TempDir()
	unlock, err := holdState(t, state)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := unlock(); err != nil {
			t.Error(err)
		}
	})
	dir := filepath.Join(state, "discovery")
	enrollment, err := rendezvous.NewEnrollment(dir)
	if err != nil {
		t.Fatal(err)
	}
	execution := "0123456789abcdef0123456789abcdef"
	if provision {
		transport = provisionMesh(t, dir)
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		t.Fatal(err)
	}
	if err := enrollment.Initialize(ctx, execution, secret); err != nil {
		t.Fatal(err)
	}
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	collector := metrics.NewCollector(metricscfg.Config{})
	t.Cleanup(func() { collector.Close() })
	bus := eventbus.NewBus()
	owner, err := stackpkg.AssembleStack(stackpkg.StackConfig{
		Meta:     clusterapi.NodeMeta{internode.MetadataSurfaceProtocol: "1"},
		NodeName: "owner", Logger: zap.NewNop(), Bus: bus, Collector: collector, Transcoder: payload.NewTranscoder(),
		MembershipBindAddr: "127.0.0.1", InternodeBindAddr: "127.0.0.1",
		SecretKey: base64.StdEncoding.EncodeToString(secret), InternodeIdentityKey: base64.RawStdEncoding.EncodeToString(private),
		InternodeTrustedPeerKeys: map[string]string{"owner": base64.RawStdEncoding.EncodeToString(public)},
		InternodeTLS:             transport,
		InternodePeerKeySource:   clusterapi.PeerKeySource(func(node string) (ed25519.PublicKey, bool) { return enrollment.Resolve(ctx, execution, node) }),
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := owner.Stop(); err != nil {
			t.Error(err)
		}
	})
	root, names, err := prepareNames(ctx, owner, bus)
	if err != nil {
		t.Fatal(err)
	}
	ctx = root
	t.Cleanup(func() {
		if err := names.(boot.Stopper).Stop(context.Background()); err != nil {
			t.Error(err)
		}
	})
	if err := owner.Start(ctx); err != nil {
		t.Fatal(err)
	}
	if err := names.(boot.Starter).Start(ctx); err != nil {
		t.Fatal(err)
	}
	descriptor, err := rendezvous.Capture(owner.Membership.LocalNode(), execution)
	if err != nil {
		t.Fatal(err)
	}
	store, err := rendezvous.New(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Publish(ctx, descriptor); err != nil {
		t.Fatal(err)
	}
	return ctx, dir, owner, enrollment, descriptor
}

// provisionMesh writes the owner's mesh credential and authority pool into
// directory the way the owner route does, for the owner and its local clients.
func provisionMesh(t *testing.T, directory string) internode.ManagerTLSConfig {
	t.Helper()
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	document, err := meshtls.NewAuthority(now)
	if err != nil {
		t.Fatal(err)
	}
	authority, err := meshtls.DecodeAuthority(document, now)
	if err != nil {
		t.Fatal(err)
	}
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := authority.Issue(public, nil, now)
	if err != nil {
		t.Fatal(err)
	}
	credential, err := meshtls.Credential(leaf, private)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, meshtls.CredentialFile), credential, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, meshtls.AuthoritiesFile), authority.Certificate(), 0o600); err != nil {
		t.Fatal(err)
	}
	return meshtls.Config(directory)
}

// joinFresh enrolls a fresh identity with the fixture owner for the callback's
// duration and joins with it, as the launch route enrolls and joins a client.
func joinFresh(ctx context.Context, dir string, transport internode.ManagerTLSConfig, run func(context.Context, *stackpkg.Stack, rendezvous.Descriptor) error) (result error) {
	store, err := rendezvous.New(dir)
	if err != nil {
		return err
	}
	descriptor, err := store.Read(ctx)
	if err != nil {
		return err
	}
	enrollment, err := rendezvous.NewEnrollment(dir)
	if err != nil {
		return err
	}
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		return err
	}
	node := "bee-client-" + hex.EncodeToString(id[:])
	lease, _, err := enrollment.RegisterHeld(ctx, descriptor.Execution, node, public)
	if err != nil {
		return err
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), cleanupTimeout)
		defer cancel()
		result = errors.Join(result, lease.Close(cleanup))
	}()
	return Joined(ctx, JoinConfig{Directory: dir, EnrollmentDirectory: dir, Node: node, Key: private, TLS: transport}, run)
}

// This is a genuinely separate OS client, using the same executable solely as
// an acceptance harness. No fixture preset client key or PID is supplied.
func TestLocalSeparateClientProcess(t *testing.T) {
	ctx, dir, owner, enrollment, descriptor := localOwner(t)
	report := filepath.Join(t.TempDir(), "client-node")
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.CommandContext(ctx, executable, "-test.run=^TestLocalClientSubprocess$")
	cmd.Env = append(os.Environ(), "BEE_MESH_TEST_DISCOVERY="+dir, "BEE_MESH_TEST_REPORT="+report)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("client failed: %v\n%s", err, output)
	}
	node, err := os.ReadFile(report)
	if err != nil {
		t.Fatal(err)
	}
	if len(node) == 0 {
		t.Fatal("missing fresh client identity")
	}
	if _, ok := enrollment.Resolve(ctx, descriptor.Execution, string(node)); ok {
		t.Fatal("client enrollment leaked after exit")
	}
	if owner.Membership.LocalNode().ID != "owner" {
		t.Fatal("owner changed")
	}
	if owned, err := app.Owned(filepath.Dir(dir)); err != nil || !owned {
		t.Fatalf("owner lock disturbed: owned=%v err=%v", owned, err)
	}
	entries, err := os.ReadDir(filepath.Dir(dir))
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if filepath.Ext(entry.Name()) == ".db" || filepath.Ext(entry.Name()) == ".sqlite" {
			t.Fatalf("client created application database %s", entry.Name())
		}
	}
}
func TestLocalClientSubprocess(t *testing.T) {
	dir := os.Getenv("BEE_MESH_TEST_DISCOVERY")
	if dir == "" {
		t.Skip("subprocess helper")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	if err := joinFresh(ctx, dir, internode.ManagerTLSConfig{}, func(ctx context.Context, stack *stackpkg.Stack, owner rendezvous.Descriptor) error {
		if owner.Node != "owner" {
			return errors.New("wrong owner")
		}
		if len(stack.ConnMgr.ConnectedNodes()) != 1 {
			return errors.New("unexpected connections")
		}
		return os.WriteFile(os.Getenv("BEE_MESH_TEST_REPORT"), []byte(stack.Node.ID()), 0600)
	}); err != nil {
		t.Fatal(err)
	}
}

func TestLocalCallbackFailureCleansEnrollment(t *testing.T) {
	ctx, dir, _, enrollment, descriptor := localOwner(t)
	stopped := errors.New("admission refused")
	var node string
	err := joinFresh(ctx, dir, internode.ManagerTLSConfig{}, func(_ context.Context, stack *stackpkg.Stack, _ rendezvous.Descriptor) error {
		node = stack.Node.ID()
		return stopped
	})
	if !errors.Is(err, stopped) {
		t.Fatalf("lost callback failure: %v", err)
	}
	if node == "" {
		t.Fatal("callback not reached")
	}
	if _, ok := enrollment.Resolve(ctx, descriptor.Execution, node); ok {
		t.Fatal("enrollment survived rejected admission")
	}
}

func TestLocalRejectsStaleEndpointBeforeAdmission(t *testing.T) {
	ctx, dir, _, _, descriptor := localOwner(t)
	store, _ := rendezvous.New(dir)
	descriptor.Transport = "127.0.0.1:1"
	if err := store.Publish(ctx, descriptor); err != nil {
		t.Fatal(err)
	}
	err := joinFresh(ctx, dir, internode.ManagerTLSConfig{}, func(context.Context, *stackpkg.Stack, rendezvous.Descriptor) error {
		t.Error("stale endpoint reached admission")
		return nil
	})
	if !errors.Is(err, rendezvous.ErrOwnerChanged) {
		t.Fatalf("expected stale owner refusal: %v", err)
	}
}

func TestStartupDeadlineDoesNotEndAdmittedClient(t *testing.T) {
	ctx, dir, _, _, _ := localOwner(t)
	err := joinFresh(ctx, dir, internode.ManagerTLSConfig{}, func(ctx context.Context, stack *stackpkg.Stack, _ rendezvous.Descriptor) error {
		timer := time.NewTimer(startupTimeout + 100*time.Millisecond)
		defer timer.Stop()
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-timer.C:
		}
		if len(stack.ConnMgr.ConnectedNodes()) != 1 {
			return errors.New("startup deadline closed live transport")
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestMissingOwnerCreatesNoClientState(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "missing")
	err := joinFresh(context.Background(), dir, internode.ManagerTLSConfig{}, func(context.Context, *stackpkg.Stack, rendezvous.Descriptor) error {
		t.Error("missing owner reached callback")
		return nil
	})
	if !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("missing owner: %v", err)
	}
	if _, err := os.Stat(dir); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("created discovery directory: %v", err)
	}
}
