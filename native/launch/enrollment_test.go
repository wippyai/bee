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

	"github.com/wippyai/runtime/api/boot"
	"github.com/wippyai/runtime/api/registry"
	bootpkg "github.com/wippyai/runtime/boot"
	"go.uber.org/zap"
)

// recordingRegistry captures the change sets the publisher applies.
type recordingRegistry struct {
	applied   int
	lastNodes []string
}

func (r *recordingRegistry) Apply(_ context.Context, changes registry.ChangeSet) (registry.Version, error) {
	r.applied++
	r.lastNodes = r.lastNodes[:0]
	for _, operation := range changes {
		raw, _ := operation.Entry.Data.Data().(map[string]any)
		nodes, _ := raw["nodes"].([]any)
		for _, node := range nodes {
			if name, ok := node.(string); ok {
				r.lastNodes = append(r.lastNodes, name)
			}
		}
	}
	sort.Strings(r.lastNodes)
	return nil, nil
}

// prepareOwnerState creates the owner files the publisher reads.
func prepareOwnerState(t *testing.T, state string) {
	t.Helper()
	if _, _, err := prepareOwner(state); err != nil {
		t.Fatal(err)
	}
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
	changes, err := enrollmentChangeSet(trusted)
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
	if reg.applied != 1 {
		t.Fatalf("applied %d change sets, want 1", reg.applied)
	}
	if len(reg.lastNodes) != 2 || reg.lastNodes[0] != "client-a" || reg.lastNodes[1] != "client-b" {
		t.Fatalf("published nodes = %v", reg.lastNodes)
	}

	// A departure retires the node: its key file is gone and the publisher no
	// longer names it.
	if err := os.Remove(filepath.Join(trusted, "client-b.pub")); err != nil {
		t.Fatal(err)
	}
	changes, err = enrollmentChangeSet(trusted)
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
	changes, err := enrollmentChangeSet(trusted)
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

func (r *flakyRegistry) Apply(_ context.Context, changes registry.ChangeSet) (registry.Version, error) {
	if r.failures.Load() > 0 {
		r.failures.Add(-1)
		return nil, errors.New("entry does not exist")
	}
	r.applied.Add(1)
	return nil, nil
}

func TestEnrollmentPublisherRetriesUntilTheEntryExists(t *testing.T) {
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
	ctx := registry.WithRegistry(base, reg)
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

func TestOwnerComponentsIncludeEnrollmentPublisher(t *testing.T) {
	state := t.TempDir()
	prepareOwnerState(t, state)
	components, err := ownerComponents(state, "0123456789abcdef0123456789abcdef")
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
	if len(components) != 2 || names[0] != "bee.hive.rendezvous" || names[1] != "bee.launch.enrollment" {
		t.Fatalf("owner components = %v", names)
	}
	// A relative state directory is refused before any filesystem work.
	if _, err := ownerComponents("relative", "0123456789abcdef0123456789abcdef"); err == nil {
		t.Fatal("relative state directory was accepted")
	}
}

func TestEnrollmentPublisherHandlesMissingDirectory(t *testing.T) {
	state := t.TempDir()
	prepareOwnerState(t, state)
	changes, err := enrollmentChangeSet(ownerTrustedDirectory(state))
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
