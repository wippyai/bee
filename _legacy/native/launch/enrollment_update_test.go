// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/wippyai/bee/native/hive/rendezvous"
	"github.com/wippyai/runtime/api/boot"
	"github.com/wippyai/runtime/api/registry"
	bootpkg "github.com/wippyai/runtime/boot"
	regsystem "github.com/wippyai/runtime/system/registry"
	historymem "github.com/wippyai/runtime/system/registry/history/memory"
	"github.com/wippyai/runtime/system/registry/topology"
	"go.uber.org/zap"
)

// This runner exercises the real registry's durable/overlay composition while
// accepting the ordinary entry transitions delivered to a registry handler.
type enrollmentTransition struct{}

func (enrollmentTransition) Transition(_ context.Context, from registry.State, changes registry.ChangeSet, _ func(context.Context)) (registry.State, error) {
	entries := make(map[registry.ID]registry.Entry)
	for _, entry := range from {
		entries[entry.ID] = entry
	}
	for _, change := range changes {
		if change.Kind == registry.EntryDelete {
			delete(entries, change.Entry.ID)
		} else {
			entries[change.Entry.ID] = change.Entry
		}
	}
	state := make(registry.State, 0, len(entries))
	for _, entry := range entries {
		state = append(state, entry)
	}
	return state, nil
}

func TestEnrollmentSurvivesPackageReplacementAndStillRevokesDepartures(t *testing.T) {
	state := t.TempDir()
	prepareOwnerState(t, state)
	_, release := holdClient(t, state, "client-live")
	defer release()
	history := historymem.New()
	resolver := topology.NewResolver()
	reg := regsystem.NewRegistry(history, enrollmentTransition{}, topology.NewStateBuilder(zap.NewNop(), resolver), resolver, zap.NewNop())
	root, err := history.GetVersion(registry.RootVersion)
	if err != nil {
		t.Fatal(err)
	}
	packaged := enrollmentChange(nil, nil)[0].Entry
	packaged.ID = registry.ParseID("bee.hive.supervisor:enrollment_nodes")
	if err := reg.LoadState(context.Background(), registry.State{packaged}, root); err != nil {
		t.Fatal(err)
	}
	execution, err := readExecution(ownerDirectory(state))
	if err != nil {
		t.Fatal(err)
	}
	secret, err := readMembershipSecret(state)
	if err != nil {
		t.Fatal(err)
	}
	p := &enrollmentPublisherComponent{state: state, directory: ownerDirectory(state), trusted: ownerTrustedDirectory(state),
		execution: execution, secret: secret, node: ownerNodeName(state)}
	local, err := rendezvous.NewEnrollment(p.directory)
	if err != nil {
		t.Fatal(err)
	}
	base, err := bootpkg.NewBootstrapContext(zap.NewNop(), boot.NewConfig())
	if err != nil {
		t.Fatal(err)
	}
	ctx := liveOwner(t, state, base)
	if err := p.publish(ctx, reg, local); err != nil {
		t.Fatal(err)
	}
	// A root update publishes the package's empty default with the same ID.
	// The live host selection must continue to be the effective admission.
	if _, err := reg.Apply(ctx, registry.ChangeSet{{Kind: registry.EntryUpdate, Entry: packaged}}); err != nil {
		t.Fatal(err)
	}
	entry, err := reg.GetEntry(registry.ParseID(enrollmentEntry))
	if err != nil {
		t.Fatal(err)
	}
	nodes := entry.Data.Data().(map[string]any)["nodes"].([]any)
	if len(nodes) != 1 || nodes[0] != "client-live" {
		t.Fatalf("package replacement erased live host enrollment: %v", nodes)
	}
	if err := os.Remove(filepath.Join(p.trusted, "client-live.pub")); err != nil {
		t.Fatal(err)
	}
	if err := p.publish(ctx, reg, local); err != nil {
		t.Fatal(err)
	}
	entry, err = reg.GetEntry(registry.ParseID(enrollmentEntry))
	if err != nil {
		t.Fatal(err)
	}
	if nodes := entry.Data.Data().(map[string]any)["nodes"].([]any); len(nodes) != 0 {
		t.Fatalf("departed client retained admission: %v", nodes)
	}
	if _, ok := local.Resolve(ctx, execution, "client-live"); ok {
		t.Fatal("departed client retained local enrollment")
	}
}
