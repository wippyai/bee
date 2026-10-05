// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"sync/atomic"
	"testing"
	"time"

	"github.com/wippyai/bee/native/hive/rendezvous"
	"github.com/wippyai/bee/native/internal/privatefile"
	"github.com/wippyai/runtime/api/boot"
	clusterapi "github.com/wippyai/runtime/api/cluster"
	ctxapi "github.com/wippyai/runtime/api/context"
	eventapi "github.com/wippyai/runtime/api/event"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/api/registry"
	topapi "github.com/wippyai/runtime/api/topology"
	bootpkg "github.com/wippyai/runtime/boot"
	topologysys "github.com/wippyai/runtime/system/topology"
	"go.uber.org/zap"
)

// recordingRegistry captures the change sets the publisher applies.
type recordingRegistry struct {
	enrollmentRegistryStub
	applied   atomic.Int64
	lastNodes []string
	lastPeers []string
}

func (r *recordingRegistry) ApplyOverlay(ctx context.Context, owner string, generation uint64, changes registry.ChangeSet) (uint64, error) {
	_, err := r.Apply(ctx, changes)
	return generation + 1, err
}

func (r *recordingRegistry) Apply(_ context.Context, changes registry.ChangeSet) (registry.Version, error) {
	r.applied.Add(1)
	r.lastNodes, r.lastPeers = nil, nil
	for _, operation := range changes {
		raw, _ := operation.Entry.Data.Data().(map[string]any)
		for field, into := range map[string]*[]string{"nodes": &r.lastNodes, "peers": &r.lastPeers} {
			list, present := raw[field].([]any)
			if !present {
				return nil, errors.New("enrollment entry lacks " + field)
			}
			for _, node := range list {
				if name, ok := node.(string); ok {
					*into = append(*into, name)
				}
			}
		}
	}
	sort.Strings(r.lastNodes)
	sort.Strings(r.lastPeers)
	return nil, nil
}

// prepareOwnerState creates the owner files the publisher reads.
func prepareOwnerState(t *testing.T, state string) {
	t.Helper()
	_, release, err := prepareOwner(state, true)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := release(); err != nil {
			t.Error(err)
		}
	})
}

func writeClientKey(t *testing.T, trusted, node string) ed25519.PublicKey {
	t.Helper()
	public, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(trusted, 0o700); err != nil {
		t.Fatal(err)
	}
	encoded := base64.RawStdEncoding.EncodeToString(public)
	if err := os.WriteFile(filepath.Join(trusted, node+".pub"), []byte(encoded+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return public
}

func TestEnrollmentPublisherAppliesAddedAndRetiredNodes(t *testing.T) {
	state := t.TempDir()
	prepareOwnerState(t, state)
	trusted := ownerTrustedDirectory(state)
	writeClientKey(t, trusted, "client-a")
	writeClientKey(t, trusted, "client-b")

	reg := &recordingRegistry{}
	changes, err := enrollmentChangeSet(state)
	if err != nil {
		t.Fatal(err)
	}
	if len(changes) != 1 || changes[0].Kind != registry.EntryUpdate {
		t.Fatalf("change set = %#v", changes)
	}
	if changes[0].Entry.ID.String() != enrollmentEntry {
		t.Fatalf("entry id = %q, want %q", changes[0].Entry.ID.String(), enrollmentEntry)
	}
	if changes[0].Entry.Kind != enrollmentEntryKind {
		t.Fatalf("entry kind = %q", changes[0].Entry.Kind)
	}
	if _, err := reg.Apply(context.Background(), changes); err != nil {
		t.Fatal(err)
	}
	if reg.applied.Load() != 1 {
		t.Fatalf("applied %d change sets, want 1", reg.applied.Load())
	}
	if len(reg.lastNodes) != 2 || reg.lastNodes[0] != "client-a" || reg.lastNodes[1] != "client-b" {
		t.Fatalf("published nodes = %v", reg.lastNodes)
	}

	// A departure retires the node: its key file is gone and the publisher no
	// longer names it.
	if err := os.Remove(filepath.Join(trusted, "client-b.pub")); err != nil {
		t.Fatal(err)
	}
	changes, err = enrollmentChangeSet(state)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := reg.Apply(context.Background(), changes); err != nil {
		t.Fatal(err)
	}
	if len(reg.lastNodes) != 1 || reg.lastNodes[0] != "client-a" {
		t.Fatalf("published nodes after departure = %v", reg.lastNodes)
	}
}

func TestEnrollmentPublisherIgnoresMalformedTrustedFiles(t *testing.T) {
	state := t.TempDir()
	prepareOwnerState(t, state)
	trusted := ownerTrustedDirectory(state)
	writeClientKey(t, trusted, "client-good")
	// A malformed key, a wrong-length key and an unrelated file are all ignored.
	if err := os.WriteFile(filepath.Join(trusted, "client-bad.pub"), []byte("not-base64!\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(trusted, "client-short.pub"), []byte("AAAA\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(trusted, "notes.txt"), []byte("ignore\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	changes, err := enrollmentChangeSet(state)
	if err != nil {
		t.Fatal(err)
	}
	reg := &recordingRegistry{}
	if _, err := reg.Apply(context.Background(), changes); err != nil {
		t.Fatal(err)
	}
	if len(reg.lastNodes) != 1 || reg.lastNodes[0] != "client-good" {
		t.Fatalf("published nodes = %v", reg.lastNodes)
	}
}

// flakyRegistry fails the first applies, modelling the runtime applying the
// deployment's entries after boot components start.
type flakyRegistry struct {
	enrollmentRegistryStub
	failures atomic.Int64
	applied  atomic.Int64
}

func (r *flakyRegistry) ApplyOverlay(ctx context.Context, owner string, generation uint64, changes registry.ChangeSet) (uint64, error) {
	_, err := r.Apply(ctx, changes)
	return generation + 1, err
}

func (r *flakyRegistry) Apply(_ context.Context, changes registry.ChangeSet) (registry.Version, error) {
	if r.failures.Load() > 0 {
		r.failures.Add(-1)
		return nil, errors.New("entry does not exist")
	}
	r.applied.Add(1)
	return nil, nil
}

func TestEnrollmentPublisherRetriesUntilTheRegistryAccepts(t *testing.T) {
	state := t.TempDir()
	prepareOwnerState(t, state)
	writeClientKey(t, ownerTrustedDirectory(state), "client-a")
	reg := &flakyRegistry{}
	reg.failures.Store(2)
	component, err := enrollmentPublisher(state)
	if err != nil {
		t.Fatal(err)
	}
	base, err := bootpkg.NewBootstrapContext(zap.NewNop(), boot.NewConfig())
	if err != nil {
		t.Fatal(err)
	}
	ctx := liveOwner(t, state, registry.WithRegistry(base, reg))
	starter, ok := component.(boot.Starter)
	if !ok {
		t.Fatal("publisher is not a starter")
	}
	if err := starter.Start(ctx); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for reg.applied.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if reg.applied.Load() == 0 {
		t.Fatal("publisher never applied after the entry appeared")
	}
	if stopper, ok := component.(boot.Stopper); ok {
		if err := stopper.Stop(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
}

// refusingRegistry refuses applies while refuse is set, modelling a registry
// that is busy when an enrollment change arrives.
type refusingRegistry struct {
	recordingRegistry
	refused atomic.Int64
	refuse  atomic.Bool
}

func (r *refusingRegistry) ApplyOverlay(ctx context.Context, owner string, generation uint64, changes registry.ChangeSet) (uint64, error) {
	_, err := r.Apply(ctx, changes)
	return generation + 1, err
}

func (r *refusingRegistry) Apply(ctx context.Context, changes registry.ChangeSet) (registry.Version, error) {
	if r.refuse.Load() {
		r.refused.Add(1)
		return nil, errors.New("registry is busy")
	}
	return r.recordingRegistry.Apply(ctx, changes)
}

func TestEnrollmentPublisherRetriesARefusedChangeWithoutAnotherEvent(t *testing.T) {
	state := t.TempDir()
	prepareOwnerState(t, state)
	reg := &refusingRegistry{}
	base, err := bootpkg.NewBootstrapContext(zap.NewNop(), boot.NewConfig())
	if err != nil {
		t.Fatal(err)
	}
	component, err := enrollmentPublisher(state)
	if err != nil {
		t.Fatal(err)
	}
	if err := component.(boot.Starter).Start(liveOwner(t, state, registry.WithRegistry(base, reg))); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = component.(boot.Stopper).Stop(context.Background()) }()
	waitForEnrollment(t, func() bool { return reg.applied.Load() == 1 })

	reg.refuse.Store(true)
	release, err := enrollClient(context.Background(), state, "client-refused", makeTestPublicKey(t))
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = release() }()
	waitForEnrollment(t, func() bool { return reg.refused.Load() > 0 })
	reg.refuse.Store(false)
	waitForEnrollment(t, func() bool { return reg.applied.Load() == 2 })
}

func TestEnrollmentPublisherPublishesFilesystemChangesAndStopsRefreshing(t *testing.T) {
	state := t.TempDir()
	prepareOwnerState(t, state)
	reg := &recordingRegistry{}
	base, err := bootpkg.NewBootstrapContext(zap.NewNop(), boot.NewConfig())
	if err != nil {
		t.Fatal(err)
	}
	component, err := enrollmentPublisher(state)
	if err != nil {
		t.Fatal(err)
	}
	if err := component.(boot.Starter).Start(liveOwner(t, state, registry.WithRegistry(base, reg))); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = component.(boot.Stopper).Stop(context.Background()) }()
	waitForEnrollment(t, func() bool { return reg.applied.Load() == 1 })
	time.Sleep(1200 * time.Millisecond)
	if got := reg.applied.Load(); got != 1 {
		t.Fatalf("unchanged enrollment applied %d times after startup, want 1", got)
	}

	public := makeTestPublicKey(t)
	release, err := enrollClient(context.Background(), state, "client-event", public)
	if err != nil {
		t.Fatal(err)
	}
	execution, err := readExecution(ownerDirectory(state))
	if err != nil {
		t.Fatal(err)
	}
	local, err := rendezvous.NewEnrollment(ownerDirectory(state))
	if err != nil {
		t.Fatal(err)
	}
	waitForEnrollment(t, func() bool {
		key, ok := local.Resolve(context.Background(), execution, "client-event")
		return ok && key.Equal(public)
	})
	if err := release(); err != nil {
		t.Fatal(err)
	}
	waitForEnrollment(t, func() bool {
		_, ok := local.Resolve(context.Background(), execution, "client-event")
		return !ok
	})
}

func makeTestPublicKey(t *testing.T) ed25519.PublicKey {
	t.Helper()
	public, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return public
}

func waitForEnrollment(t *testing.T, ready func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !ready() && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if !ready() {
		t.Fatal("enrollment change was not published")
	}
}

func TestOwnerComponentsIncludeEnrollmentPublisher(t *testing.T) {
	state := t.TempDir()
	prepareOwnerState(t, state)
	components, err := ownerComponents(state, "0123456789abcdef0123456789abcdef", "")
	if err != nil {
		t.Fatal(err)
	}
	names := make([]string, 0, len(components))
	for _, component := range components {
		names = append(names, component.Name())
		if deps := component.DependsOn(); len(deps) != 1 || deps[0] != "cluster" {
			t.Fatalf("component %s dependencies = %v", component.Name(), deps)
		}
	}
	if len(components) != 3 || names[0] != "bee.hive.rendezvous" || names[1] != "bee.launch.join" || names[2] != "bee.launch.enrollment" {
		t.Fatalf("owner components = %v", names)
	}
	// A relative state directory is refused before any filesystem work.
	if _, err := ownerComponents("relative", "0123456789abcdef0123456789abcdef", ""); err == nil {
		t.Fatal("relative state directory was accepted")
	}
}

func TestEnrollmentPublisherHandlesMissingDirectory(t *testing.T) {
	state := t.TempDir()
	prepareOwnerState(t, state)
	changes, err := enrollmentChangeSet(state)
	if err != nil {
		t.Fatal(err)
	}
	reg := &recordingRegistry{}
	if _, err := reg.Apply(context.Background(), changes); err != nil {
		t.Fatal(err)
	}
	if len(reg.lastNodes) != 0 {
		t.Fatalf("published nodes for absent directory = %v", reg.lastNodes)
	}
}

// orderedRegistry refuses the enrollment entry until opened and records
// whether the client already resolved in the local enrollment at each apply.
type orderedRegistry struct {
	enrollmentRegistryStub
	open     atomic.Bool
	applied  atomic.Int64
	early    atomic.Bool
	resolved func() bool
}

func (r *orderedRegistry) ApplyOverlay(ctx context.Context, owner string, generation uint64, changes registry.ChangeSet) (uint64, error) {
	_, err := r.Apply(ctx, changes)
	return generation + 1, err
}

func (r *orderedRegistry) Apply(_ context.Context, _ registry.ChangeSet) (registry.Version, error) {
	if r.resolved() {
		if r.applied.Load() == 0 {
			r.early.Store(true)
		}
	}
	if !r.open.Load() {
		return nil, errors.New("entry does not exist")
	}
	r.applied.Add(1)
	return nil, nil
}

// A client waits on the local enrollment and then sends its first request, so
// the enrollment may list a node only after the host entry the supervisor
// admits from names it.
func TestEnrollmentPublisherListsClientsOnlyAfterTheEntryNamesThem(t *testing.T) {
	state := t.TempDir()
	prepareOwnerState(t, state)
	_, release := holdClient(t, state, "client-a")
	defer release()
	execution, err := readExecution(ownerDirectory(state))
	if err != nil {
		t.Fatal(err)
	}
	local, err := rendezvous.NewEnrollment(ownerDirectory(state))
	if err != nil {
		t.Fatal(err)
	}
	resolved := func() bool {
		_, ok := local.Resolve(context.Background(), execution, "client-a")
		return ok
	}
	reg := &orderedRegistry{resolved: resolved}
	component, err := enrollmentPublisher(state)
	if err != nil {
		t.Fatal(err)
	}
	base, err := bootpkg.NewBootstrapContext(zap.NewNop(), boot.NewConfig())
	if err != nil {
		t.Fatal(err)
	}
	starter, ok := component.(boot.Starter)
	if !ok {
		t.Fatal("publisher is not a starter")
	}
	if err := starter.Start(liveOwner(t, state, registry.WithRegistry(base, reg))); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if stopper, ok := component.(boot.Stopper); ok {
			_ = stopper.Stop(context.Background())
		}
	}()
	// The entry stays unwritable across more than one refresh interval.
	refused := time.Now().Add(1500 * time.Millisecond)
	for time.Now().Before(refused) {
		if resolved() {
			t.Fatal("the local enrollment listed a client the host entry does not name")
		}
		time.Sleep(20 * time.Millisecond)
	}
	reg.open.Store(true)
	deadline := time.Now().Add(5 * time.Second)
	for !resolved() && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if !resolved() {
		t.Fatal("the local enrollment never listed the enrolled client")
	}
	if reg.early.Load() {
		t.Fatal("the local enrollment listed the client before the host entry was written")
	}
}

// liveOwner publishes the descriptor a booted owner writes and registers its
// supervisor, the preconditions under which the publisher lists clients.
func liveOwner(t *testing.T, state string, ctx context.Context) context.Context {
	t.Helper()
	execution, err := readExecution(ownerDirectory(state))
	if err != nil {
		t.Fatal(err)
	}
	store, err := rendezvous.New(filepath.Join(state, rendezvous.DirectoryName))
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Publish(context.Background(), rendezvous.Descriptor{Version: 1, Execution: execution, Node: ownerNodeName(state),
		Gossip: "127.0.0.1:4100", Transport: "127.0.0.1:4101", PublicKey: base64.RawStdEncoding.EncodeToString(make([]byte, ed25519.PublicKeySize))}); err != nil {
		t.Fatal(err)
	}
	names := topologysys.NewPIDRegistry()
	if _, err := names.Register("bee.hive.supervisor", pid.PID{Node: ownerNodeName(state), Host: "bee.hive.service:supervisor_host", UniqID: "0x0000e"}); err != nil {
		t.Fatal(err)
	}
	return topapi.WithRegistry(ctx, names)
}

// holdClient models a live client: it holds its node's liveness lock.
func holdClient(t *testing.T, state, node string) (ed25519.PublicKey, func()) {
	t.Helper()
	unlock, err := privatefile.TryLock(context.Background(), ownerTrustedDirectory(state), node+".lock")
	if err != nil {
		t.Fatal(err)
	}
	public := writeClientKey(t, ownerTrustedDirectory(state), node)
	return public, func() {
		if err := unlock(); err != nil {
			t.Fatal(err)
		}
	}
}

// A client whose process is gone no longer holds its liveness lock; the owner
// retires its key from the trusted directory, the host entry and the local
// enrollment, while a live client stays enrolled.
func TestEnrollmentPublisherRetiresDepartedClients(t *testing.T) {
	state := t.TempDir()
	prepareOwnerState(t, state)
	liveKey, releaseLive := holdClient(t, state, "client-live")
	defer releaseLive()
	_, releaseGone := holdClient(t, state, "client-gone")
	execution, err := readExecution(ownerDirectory(state))
	if err != nil {
		t.Fatal(err)
	}
	local, err := rendezvous.NewEnrollment(ownerDirectory(state))
	if err != nil {
		t.Fatal(err)
	}
	component, err := enrollmentPublisher(state)
	if err != nil {
		t.Fatal(err)
	}
	publisher := component.(boot.Starter)
	reg := &flakyRegistry{}
	base, err := bootpkg.NewBootstrapContext(zap.NewNop(), boot.NewConfig())
	if err != nil {
		t.Fatal(err)
	}
	ownerContext := liveOwner(t, state, registry.WithRegistry(base, reg))
	bus := eventapi.GetBus(ownerContext)
	if bus == nil {
		t.Fatal("test owner context has no event bus")
	}
	if err := publisher.Start(ownerContext); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = component.(boot.Stopper).Stop(context.Background()) }()
	resolved := func(node string) bool {
		_, ok := local.Resolve(context.Background(), execution, node)
		return ok
	}
	deadline := time.Now().Add(5 * time.Second)
	for !(resolved("client-live") && resolved("client-gone")) && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if !resolved("client-gone") {
		t.Fatal("a live client was never enrolled")
	}
	releaseGone()
	bus.Send(context.Background(), eventapi.Event{System: clusterapi.System, Kind: clusterapi.NodeLeft,
		Data: clusterapi.NodeEvent{Node: clusterapi.NodeInfo{ID: "client-gone"}}})
	deadline = time.Now().Add(5 * time.Second)
	for resolved("client-gone") && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if resolved("client-gone") {
		t.Fatal("a departed client stayed in the local enrollment")
	}
	if _, err := os.Stat(filepath.Join(ownerTrustedDirectory(state), "client-gone.pub")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a departed client's key stayed trusted: %v", err)
	}
	key, ok := local.Resolve(context.Background(), execution, "client-live")
	if !ok || !key.Equal(liveKey) {
		t.Fatal("the live client lost its enrollment")
	}
}

// A Hive peer is pinned durably in the peers directory: the entry names it
// under peers, never as a local client, and the liveness sweep that retires
// departed clients leaves it in place.
func TestEnrollmentPublisherPublishesPinnedPeers(t *testing.T) {
	state := t.TempDir()
	prepareOwnerState(t, state)
	writeClientKey(t, ownerPeersDirectory(state), "bee-owner-peer")
	_, release := holdClient(t, state, "client-live")
	defer release()
	if err := retireDepartedClients(context.Background(), ownerTrustedDirectory(state)); err != nil {
		t.Fatal(err)
	}
	changes, err := enrollmentChangeSet(state)
	if err != nil {
		t.Fatal(err)
	}
	reg := &recordingRegistry{}
	if _, err := reg.Apply(context.Background(), changes); err != nil {
		t.Fatal(err)
	}
	if len(reg.lastNodes) != 1 || reg.lastNodes[0] != "client-live" {
		t.Fatalf("published local clients = %v", reg.lastNodes)
	}
	if len(reg.lastPeers) != 1 || reg.lastPeers[0] != "bee-owner-peer" {
		t.Fatalf("published peers = %v", reg.lastPeers)
	}
}

// A client waits on the local enrollment and then addresses the supervisor the
// descriptor publishes. The owner lists a client only once this boot's
// supervisor address is published, so the client never resolves a supervisor
// from a name a Hive peer still carries from the owner's previous boot.
func TestEnrollmentPublisherListsClientsOnlyAfterTheSupervisorIsPublished(t *testing.T) {
	state := t.TempDir()
	prepareOwnerState(t, state)
	_, release := holdClient(t, state, "client-a")
	defer release()
	execution, err := readExecution(ownerDirectory(state))
	if err != nil {
		t.Fatal(err)
	}
	store, err := rendezvous.New(filepath.Join(state, rendezvous.DirectoryName))
	if err != nil {
		t.Fatal(err)
	}
	descriptor := rendezvous.Descriptor{Version: 1, Execution: execution, Node: ownerNodeName(state),
		Gossip: "127.0.0.1:4100", Transport: "127.0.0.1:4101", PublicKey: base64.RawStdEncoding.EncodeToString(make([]byte, ed25519.PublicKeySize))}
	if err := store.Publish(context.Background(), descriptor); err != nil {
		t.Fatal(err)
	}
	local, err := rendezvous.NewEnrollment(ownerDirectory(state))
	if err != nil {
		t.Fatal(err)
	}
	resolved := func() bool {
		_, ok := local.Resolve(context.Background(), execution, "client-a")
		return ok
	}
	names := topologysys.NewPIDRegistry()
	base, err := bootpkg.NewBootstrapContext(zap.NewNop(), boot.NewConfig())
	if err != nil {
		t.Fatal(err)
	}
	secret, err := readMembershipSecret(state)
	if err != nil {
		t.Fatal(err)
	}
	component := &enrollmentPublisherComponent{state: state, directory: ownerDirectory(state),
		trusted: ownerTrustedDirectory(state), execution: execution, secret: secret, node: ownerNodeName(state), retryInterval: time.Hour}
	reg := &flakyRegistry{}
	bus := eventapi.GetBus(base)
	if err := component.Start(topapi.WithRegistry(registry.WithRegistry(base, reg), names)); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := component.Stop(context.Background()); err != nil {
			t.Error(err)
		}
		if bus.HasSubscribers("bee.launch", "supervisor.ready") {
			t.Error("readiness subscription survived Stop")
		}
	}()
	bus.Send(context.Background(), eventapi.Event{System: "bee.launch", Kind: "supervisor.ready", Path: "forged"})
	unpublished := time.Now().Add(100 * time.Millisecond)
	for time.Now().Before(unpublished) {
		if reg.applied.Load() != 0 {
			t.Fatal("enrollment overlay published before deployment readiness")
		}
		if resolved() {
			t.Fatal("a client was listed before this boot's supervisor address was published")
		}
		time.Sleep(20 * time.Millisecond)
	}
	supervisor := pid.PID{Node: ownerNodeName(state), Host: "bee.hive.service:supervisor_host", UniqID: "0x0000e"}
	if _, err := names.Register("bee.hive.supervisor", supervisor); err != nil {
		t.Fatal(err)
	}
	bus.Send(context.Background(), eventapi.Event{System: "bee.launch", Kind: "supervisor.ready", Path: supervisor.String()})
	deadline := time.Now().Add(5 * time.Second)
	for !resolved() && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if !resolved() {
		t.Fatal("the client was never listed")
	}
	published, err := store.Read(context.Background())
	if err != nil || published.Supervisor != supervisor.String() {
		t.Fatalf("listed a client before publishing the supervisor: %+v %v", published, err)
	}
}

type composedSupervisorRegistry struct {
	topapi.PIDRegistry
	local         topapi.LocalPIDRegistry
	composedCalls int
	remote        pid.PID
}

func (r *composedSupervisorRegistry) Lookup(string) (pid.PID, bool) {
	r.composedCalls++
	return r.remote, true
}

func (r *composedSupervisorRegistry) LookupLocal(name string) (pid.PID, bool) {
	return r.local.LookupLocal(name)
}

func TestEnrollmentSupervisorUsesOnlyThisNodesLocalReadiness(t *testing.T) {
	state := t.TempDir()
	local := topologysys.NewPIDRegistry()
	names := &composedSupervisorRegistry{PIDRegistry: local, local: local,
		remote: pid.PID{Node: "previous-node", Host: "bee.hive.service:supervisor_host", UniqID: "stale"}}
	publisher := &enrollmentPublisherComponent{node: ownerNodeName(state)}
	base, err := bootpkg.NewBootstrapContext(zap.NewNop(), boot.NewConfig())
	if err != nil {
		t.Fatal(err)
	}
	ctx := topapi.WithRegistry(base, names)
	_, err = publisher.supervisor(ctx)
	if !errors.Is(err, errSupervisorPending) {
		t.Fatalf("missing local supervisor: %v", err)
	}
	current := pid.PID{Node: publisher.node, Host: "bee.hive.service:supervisor_host", UniqID: "current"}
	if _, err := local.Register("bee.hive.supervisor", current); err != nil {
		t.Fatal(err)
	}
	got, err := publisher.supervisor(ctx)
	if err != nil || got != current {
		t.Fatalf("local readiness = %v, %v", got, err)
	}
	if names.composedCalls != 0 {
		t.Fatalf("local readiness consulted distributed namespaces %d times", names.composedCalls)
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := publisher.supervisor(cancelled); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled readiness: %v", err)
	}
}

type refusingEnrollmentBus struct {
	eventapi.Bus
	kind eventapi.Kind
}

func (b refusingEnrollmentBus) SubscribeP(ctx context.Context, system eventapi.System, kind eventapi.Kind, events chan<- eventapi.Event) (eventapi.SubscriberID, error) {
	if kind == b.kind {
		return "", errors.New("subscription refused")
	}
	return b.Bus.SubscribeP(ctx, system, kind, events)
}

func TestEnrollmentPublisherCleansUpRefusedSubscriptions(t *testing.T) {
	for _, kind := range []eventapi.Kind{"supervisor.ready", clusterapi.NodeLeft} {
		t.Run(kind, func(t *testing.T) {
			state := t.TempDir()
			prepareOwnerState(t, state)
			base, err := bootpkg.NewBootstrapContext(zap.NewNop(), boot.NewConfig())
			if err != nil {
				t.Fatal(err)
			}
			bus := eventapi.GetBus(base)
			component, err := enrollmentPublisher(state)
			if err != nil {
				t.Fatal(err)
			}
			ctx := ctxapi.WithAppContext(base, ctxapi.NewAppContext())
			ctx = eventapi.WithBus(registry.WithRegistry(ctx, &flakyRegistry{}), refusingEnrollmentBus{Bus: bus, kind: kind})
			if err := component.(boot.Starter).Start(ctx); err == nil {
				t.Fatal("publisher accepted a refused subscription")
			}
			if err := component.(boot.Stopper).Stop(context.Background()); err != nil {
				t.Fatal(err)
			}
			if bus.HasSubscribers("bee.launch", "supervisor.ready") {
				t.Fatal("failed startup retained its readiness subscription")
			}
		})
	}
}
