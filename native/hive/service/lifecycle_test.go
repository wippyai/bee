// SPDX-License-Identifier: MIT
//go:build hiveintegration

package service_test

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/wippyai/runtime/api/attrs"
	"github.com/wippyai/runtime/api/boot"
	"github.com/wippyai/runtime/api/event"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/api/registry"
	"github.com/wippyai/runtime/api/supervisor"
	"github.com/wippyai/runtime/api/topology"
	bootpkg "github.com/wippyai/runtime/boot"
	"github.com/wippyai/runtime/cmd/wippy/cmd"
	"go.uber.org/zap"

	service "github.com/wippyai/bee/native/hive/service"
)

// TestHiveServiceComponent_RealRemoveAndReAddFreshPID proves:
// 1. Deleting the activation entry removes the service and unregisters supervisor PID from topology.
// 2. Re-adding the activation entry starts the supervisor under a fresh PID.
func TestHiveServiceComponent_RealRemoveAndReAddFreshPID(t *testing.T) {
	root := stageTestDirectory(t, stageOptions{})

	cfg := service.Config{
		Enabled:         true,
		ConfiguredNodes: []string{},
		Policies:        defaultTestPolicies(),
	}

	comp, err := service.New(cfg)
	if err != nil {
		t.Fatal(err)
	}

	ctx, err := bootpkg.NewBootstrapContext(zap.NewNop(), boot.NewConfig())
	if err != nil {
		t.Fatal(err)
	}

	loader, err := bootpkg.NewLoader(append(cmd.StandardComponents(), comp)...)
	if err != nil {
		t.Fatal(err)
	}

	ctx, err = loader.Load(ctx)
	if err != nil {
		t.Fatal(err)
	}

	if err = loader.Start(ctx); err != nil {
		t.Fatal(err)
	}

	defer func() {
		stop, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := loader.Shutdown(stop); err != nil {
			t.Errorf("shutdown failed: %v", err)
		}
	}()

	entries, err := boot.GetLoader(ctx).LoadFS(ctx, os.DirFS(filepath.Join(root, "src")))
	if err != nil {
		t.Fatal(err)
	}

	reg := registry.GetRegistry(ctx)
	cur, _ := reg.Current()
	if err := reg.LoadState(ctx, registry.State(entries), cur); err != nil {
		t.Fatalf("LoadState failed: %v", err)
	}

	pid1 := waitForSupervisorPID(t, ctx, 5*time.Second)
	t.Logf("generation 1 supervisor PID: %s", pid1)

	// 1. Delete the activation entry via registry ChangeSet
	actEntry, err := reg.GetEntry(registry.ParseID(service.ActivationID))
	if err != nil {
		t.Fatal(err)
	}

	deleteCS := registry.ChangeSet{
		registry.Operation{
			Kind:  registry.EntryDelete,
			Entry: actEntry,
		},
	}
	if _, err := reg.Apply(ctx, deleteCS); err != nil {
		t.Fatalf("Apply delete failed: %v", err)
	}

	waitForSupervisorUnregistered(t, ctx, 5*time.Second)
	t.Log("supervisor cleanly unregistered from topology upon deletion")

	// 2. Re-add the activation entry via registry ChangeSet
	createCS := registry.ChangeSet{
		registry.Operation{
			Kind:  registry.EntryCreate,
			Entry: actEntry,
		},
	}
	if _, err := reg.Apply(ctx, createCS); err != nil {
		t.Fatalf("Apply re-add failed: %v", err)
	}

	pid2 := waitForSupervisorPID(t, ctx, 5*time.Second)
	t.Logf("generation 2 supervisor PID: %s", pid2)

	if pid1 == pid2 {
		t.Fatalf("expected fresh PID on re-add, got same PID: %s", pid1)
	}
}

// TestHiveServiceComponent_SameIDReplacementWithinTransaction proves:
// In-place update within a registry transaction executes same-ID replacement,
// terminating the old instance and launching the fresh instance with a new PID.
func TestHiveServiceComponent_SameIDReplacementWithinTransaction(t *testing.T) {
	root := stageTestDirectory(t, stageOptions{})

	cfg := service.Config{
		Enabled:         true,
		ConfiguredNodes: []string{},
		Policies:        defaultTestPolicies(),
	}

	comp, err := service.New(cfg)
	if err != nil {
		t.Fatal(err)
	}

	ctx, err := bootpkg.NewBootstrapContext(zap.NewNop(), boot.NewConfig())
	if err != nil {
		t.Fatal(err)
	}

	loader, err := bootpkg.NewLoader(append(cmd.StandardComponents(), comp)...)
	if err != nil {
		t.Fatal(err)
	}

	ctx, err = loader.Load(ctx)
	if err != nil {
		t.Fatal(err)
	}

	if err = loader.Start(ctx); err != nil {
		t.Fatal(err)
	}

	defer func() {
		stop, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := loader.Shutdown(stop); err != nil {
			t.Errorf("shutdown failed: %v", err)
		}
	}()

	entries, err := boot.GetLoader(ctx).LoadFS(ctx, os.DirFS(filepath.Join(root, "src")))
	if err != nil {
		t.Fatal(err)
	}

	reg := registry.GetRegistry(ctx)
	cur, _ := reg.Current()
	if err := reg.LoadState(ctx, registry.State(entries), cur); err != nil {
		t.Fatalf("LoadState failed: %v", err)
	}

	pid1 := waitForSupervisorPID(t, ctx, 5*time.Second)
	t.Logf("initial supervisor PID: %s", pid1)

	actEntry, err := reg.GetEntry(registry.ParseID(service.ActivationID))
	if err != nil {
		t.Fatal(err)
	}

	// Update entry via EntryUpdate operation
	updateCS := registry.ChangeSet{
		registry.Operation{
			Kind:          registry.EntryUpdate,
			Entry:         actEntry,
			OriginalEntry: &actEntry,
		},
	}

	if _, err := reg.Apply(ctx, updateCS); err != nil {
		t.Fatalf("Apply update failed: %v", err)
	}

	// Bounded wait for replaced supervisor to register with fresh PID
	deadline := time.Now().Add(5 * time.Second)
	var pid2 pid.PID
	for time.Now().Before(deadline) {
		if p, ok := topology.GetRegistry(ctx).Lookup(service.ActorID); ok && p != pid1 {
			pid2 = p
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if pid2 == (pid.PID{}) {
		t.Fatalf("expected supervisor to restart with fresh PID after same-ID replacement")
	}
	t.Logf("same-ID replacement successful with fresh PID: %s (old: %s)", pid2, pid1)
}

// TestHiveServiceComponent_TransactionRollback proves:
// 1. Rollback reaches scheduled replacement (ServiceRemove + ServiceRegister) before rejection.
// 2. An invalid subsequent operation causes transaction discard (TxDiscard).
// 3. Discard un-stages the replacement and preserves the original supervisor PID running undisturbed.
func TestHiveServiceComponent_TransactionRollback(t *testing.T) {
	root := stageTestDirectory(t, stageOptions{})

	cfg := service.Config{
		Enabled:         true,
		ConfiguredNodes: []string{},
		Policies:        defaultTestPolicies(),
	}

	comp, err := service.New(cfg)
	if err != nil {
		t.Fatal(err)
	}

	ctx, err := bootpkg.NewBootstrapContext(zap.NewNop(), boot.NewConfig())
	if err != nil {
		t.Fatal(err)
	}

	loader, err := bootpkg.NewLoader(append(cmd.StandardComponents(), comp)...)
	if err != nil {
		t.Fatal(err)
	}

	ctx, err = loader.Load(ctx)
	if err != nil {
		t.Fatal(err)
	}

	if err = loader.Start(ctx); err != nil {
		t.Fatal(err)
	}

	defer func() {
		stop, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := loader.Shutdown(stop); err != nil {
			t.Errorf("shutdown failed: %v", err)
		}
	}()

	entries, err := boot.GetLoader(ctx).LoadFS(ctx, os.DirFS(filepath.Join(root, "src")))
	if err != nil {
		t.Fatal(err)
	}

	reg := registry.GetRegistry(ctx)
	cur, _ := reg.Current()
	if err := reg.LoadState(ctx, registry.State(entries), cur); err != nil {
		t.Fatalf("LoadState failed: %v", err)
	}

	pid1 := waitForSupervisorPID(t, ctx, 5*time.Second)
	t.Logf("initial supervisor PID: %s", pid1)

	// Subscribe to event bus to observe supervisor lifecycle events dispatched during the transaction
	bus := event.GetBus(ctx)
	if bus == nil {
		t.Fatal("event bus not available")
	}

	eventsCh := make(chan event.Event, 20)
	subID, err := bus.Subscribe(ctx, supervisor.System, eventsCh)
	if err != nil {
		t.Fatalf("failed to subscribe to supervisor events: %v", err)
	}
	defer bus.Unsubscribe(ctx, subID)

	actEntry, err := reg.GetEntry(registry.ParseID(service.ActivationID))
	if err != nil {
		t.Fatal(err)
	}

	// Prepare updated entry with modified metadata so it is a distinct, non-no-op candidate
	updatedEntry := actEntry
	updatedEntry.Meta = attrs.Bag{"candidate": "scheduled_replacement"}

	// ChangeSet:
	// Op 1: EntryUpdate on activation (schedules replacement: ServiceRemove then ServiceRegister)
	// Op 2: EntryCreate on unapproved foreign activation entry (will fail and trigger TxDiscard)
	badCS := registry.ChangeSet{
		registry.Operation{
			Kind:          registry.EntryUpdate,
			Entry:         updatedEntry,
			OriginalEntry: &actEntry,
		},
		registry.Operation{
			Kind: registry.EntryCreate,
			Entry: registry.Entry{
				ID:   registry.ParseID("bee.hive:foreign_unapproved"),
				Kind: service.ActivationKind,
			},
		},
	}

	// Apply must fail
	_, applyErr := reg.Apply(ctx, badCS)
	if applyErr == nil {
		t.Fatal("expected Apply to fail on unapproved foreign activation entry")
	}
	t.Logf("Apply rejected with expected error: %v", applyErr)

	// Verify that scheduled replacement events WERE dispatched before rejection
	var sawRemove, sawRegister bool
	timeout := time.After(1 * time.Second)
drainLoop:
	for {
		select {
		case ev := <-eventsCh:
			if ev.Path == service.ActivationID {
				if ev.Kind == supervisor.ServiceRemove {
					sawRemove = true
				}
				if ev.Kind == supervisor.ServiceRegister {
					sawRegister = true
				}
			}
			if sawRemove && sawRegister {
				break drainLoop
			}
		case <-timeout:
			break drainLoop
		}
	}

	if !sawRemove || !sawRegister {
		t.Fatalf("expected scheduled replacement (ServiceRemove=%v, ServiceRegister=%v) to be reached before rejection", sawRemove, sawRegister)
	}
	t.Log("verified rollback reached scheduled replacement (ServiceRemove + ServiceRegister) before rejection")

	// Verify old controller is retained and still running PID1
	time.Sleep(100 * time.Millisecond)
	pidAfter, ok := topology.GetRegistry(ctx).Lookup(service.ActorID)
	if !ok {
		t.Fatal("supervisor unexpectedly stopped after transaction rollback")
	}
	if pidAfter != pid1 {
		t.Fatalf("supervisor PID changed despite transaction rollback: %s != %s", pidAfter, pid1)
	}
	t.Log("transaction rollback cleanly preserved existing running supervisor PID")
}
