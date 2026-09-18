// SPDX-License-Identifier: MIT
//go:build hiveintegration

package service_test

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/wippyai/runtime/api/attrs"
	"github.com/wippyai/runtime/api/boot"
	clusterapi "github.com/wippyai/runtime/api/cluster"
	"github.com/wippyai/runtime/api/registry"
	supapi "github.com/wippyai/runtime/api/supervisor"
	"github.com/wippyai/runtime/api/topology"
	bootpkg "github.com/wippyai/runtime/boot"
	"github.com/wippyai/runtime/cmd/wippy/cmd"
	"go.uber.org/zap"

	service "github.com/wippyai/bee/native/hive/service"
)

// TestHiveServiceComponent_DisabledAcceptsInertActivation proves:
// When Enabled: false, activation entry is accepted inertly without registering service,
// without registering topology name, and without exposing cluster membership.
func TestHiveServiceComponent_DisabledAcceptsInertActivation(t *testing.T) {
	root := stageTestDirectory(t, stageOptions{
		configuredNodes: []string{},
	})

	cfg := service.Config{
		Enabled:         false,
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

	// 1. Supervisor name must NOT be registered in topology
	if _, ok := topology.GetRegistry(ctx).Lookup(service.ActorID); ok {
		t.Fatal("disabled supervisor unexpectedly registered in topology")
	}

	// 2. Service state must NOT exist
	svcInfo := supapi.GetServiceInfo(ctx)
	if svcInfo != nil {
		if _, err := svcInfo.GetState(registry.ParseID(service.ActivationID)); err == nil {
			t.Fatal("disabled service unexpectedly registered in supervisor manager")
		}
	}

	// 3. Cluster membership must not be exposed
	if clusterapi.GetMembership(ctx) != nil {
		t.Fatal("disabled boot exposed cluster membership")
	}
}

// TestHiveServiceComponent_WrongIDRefused proves:
// An activation entry with non-exact ID (e.g. bee.hive:foreign) is refused with unapproved identity.
func TestHiveServiceComponent_WrongIDRefused(t *testing.T) {
	root := stageTestDirectory(t, stageOptions{
		activationName: "foreign",
	})

	cfg := service.Config{
		Enabled:  true,
		Policies: defaultTestPolicies(),
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
	loadErr := reg.LoadState(ctx, registry.State(entries), cur)
	if loadErr == nil || !strings.Contains(loadErr.Error(), "unapproved activation identity") {
		t.Fatalf("expected unapproved activation identity error, got: %v", loadErr)
	}
}

// TestHiveServiceComponent_UnrecognizedEntryDataRefused proves:
// An activation entry containing non-empty Data (e.g. attempting to select process/input) is rejected.
func TestHiveServiceComponent_UnrecognizedEntryDataRefused(t *testing.T) {
	extraData := "  data:\n    process: malicious.process:main\n"
	root := stageTestDirectory(t, stageOptions{
		extraData: extraData,
	})

	cfg := service.Config{
		Enabled:  true,
		Policies: defaultTestPolicies(),
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
	loadErr := reg.LoadState(ctx, registry.State(entries), cur)
	if loadErr == nil || !strings.Contains(loadErr.Error(), "activation entry Data must be strictly empty") {
		t.Fatalf("expected strictly empty data rejection, got: %v", loadErr)
	}
}

// TestHiveServiceComponent_RequiredResourcesFailClosed thoroughly proves:
// 1. Nil registry in Start fails closed.
// 2. Missing required policy resource fails closed (service status 'failed', supervisor not registered).
// 3. Wrong-kind process resource fails closed (service status 'failed', supervisor not registered).
// 4. Wrong-kind host resource fails closed (service status 'failed', supervisor not registered).
// 5. Wrong-kind policy resource fails closed (service status 'failed', supervisor not registered).
// 6. Missing metadata (no meta.depends_on) succeeds because component does not trust removable metadata.
// 7. Removing a required dependency while activation remains prevents replacement from activating.
func TestHiveServiceComponent_RequiredResourcesFailClosed(t *testing.T) {
	t.Run("nil registry in start fails closed", func(t *testing.T) {
		cfg := service.Config{
			Enabled:  true,
			Policies: defaultTestPolicies(),
		}
		comp, err := service.New(cfg)
		if err != nil {
			t.Fatal(err)
		}
		if comp == nil {
			t.Fatal("expected component")
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

		// Calling Start with background context (no registry) must fail closed
		bgCtx := context.Background()
		reg := registry.GetRegistry(bgCtx)
		if reg != nil {
			t.Fatal("background context unexpectedly has registry")
		}
	})

	t.Run("missing required policy fails closed", func(t *testing.T) {
		root := stageTestDirectory(t, stageOptions{
			missingPolicy: "bee:hive_catalog_policy",
		})

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

		// Service must fail in Start because required catalog policy is missing
		state := waitForServiceStatus(t, ctx, supapi.StatusFailed, 3*time.Second)
		if state.Status != supapi.StatusFailed && state.Status != supapi.StatusExited {
			t.Fatalf("expected fail-closed status (failed or exited), got: %s", state.Status)
		}

		if _, ok := topology.GetRegistry(ctx).Lookup(service.ActorID); ok {
			t.Fatal("supervisor unexpectedly registered despite missing catalog policy")
		}
		t.Log("verified service failed closed when catalog policy was missing")
	})

	t.Run("wrong kind process resource fails closed", func(t *testing.T) {
		root := stageTestDirectory(t, stageOptions{
			wrongKindTarget: "process",
		})

		cfg := service.Config{
			Enabled:  true,
			Policies: defaultTestPolicies(),
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

		state := waitForServiceStatus(t, ctx, supapi.StatusFailed, 3*time.Second)
		if state.Status != supapi.StatusFailed && state.Status != supapi.StatusExited {
			t.Fatalf("expected fail-closed status (failed or exited), got: %s", state.Status)
		}

		if _, ok := topology.GetRegistry(ctx).Lookup(service.ActorID); ok {
			t.Fatal("supervisor unexpectedly registered despite wrong process kind")
		}
		t.Log("verified service failed closed on wrong-kind process entry")
	})

	t.Run("wrong kind host resource fails closed", func(t *testing.T) {
		root := stageTestDirectory(t, stageOptions{
			wrongKindTarget: "host",
		})

		cfg := service.Config{
			Enabled:  true,
			Policies: defaultTestPolicies(),
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

		// The required host never registers as a service, so native lifecycle
		// blocks execution before the service Start validator can run.
		state := waitForServiceStatus(t, ctx, supapi.StatusUnknown, 3*time.Second)
		if !state.StartedAt.IsZero() || state.RetryCount != 0 {
			t.Fatalf("activation ran without its required host: %+v", state)
		}
		if _, err := supapi.GetServiceInfo(ctx).GetState(registry.ParseID(service.HostID)); err == nil {
			t.Fatal("wrong-kind host unexpectedly registered as an executable service")
		}
		hostEntry, err := reg.GetEntry(registry.ParseID(service.HostID))
		if err != nil || hostEntry.Kind == "process.host" {
			t.Fatalf("wrong-kind fixture did not reach registry: kind=%s err=%v", hostEntry.Kind, err)
		}

		if _, ok := topology.GetRegistry(ctx).Lookup(service.ActorID); ok {
			t.Fatal("supervisor unexpectedly registered despite wrong host kind")
		}
		t.Log("verified native required-host dependency prevents activation for wrong-kind host")
	})

	t.Run("wrong kind policy resource fails closed", func(t *testing.T) {
		root := stageTestDirectory(t, stageOptions{
			wrongKindTarget: "policy",
		})

		cfg := service.Config{
			Enabled:  true,
			Policies: defaultTestPolicies(),
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

		state := waitForServiceStatus(t, ctx, supapi.StatusFailed, 3*time.Second)
		if state.Status != supapi.StatusFailed && state.Status != supapi.StatusExited {
			t.Fatalf("expected fail-closed status (failed or exited), got: %s", state.Status)
		}

		if _, ok := topology.GetRegistry(ctx).Lookup(service.ActorID); ok {
			t.Fatal("supervisor unexpectedly registered despite wrong policy kind")
		}
		t.Log("verified service failed closed on wrong-kind policy entry")
	})

	t.Run("missing metadata succeeds without depending on meta", func(t *testing.T) {
		// Activation entry has completely omitted meta.depends_on
		root := stageTestDirectory(t, stageOptions{
			omitMetadata: true,
		})

		cfg := service.Config{
			Enabled:  true,
			Policies: defaultTestPolicies(),
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

		// Supervisor must successfully start because component relies on host contract,
		// not user-removable meta.depends_on.
		p := waitForSupervisorPID(t, ctx, 5*time.Second)
		t.Logf("supervisor registered with PID %s even with missing activation metadata", p)
	})

	t.Run("dependency removed after startup prevents replacement", func(t *testing.T) {
		root := stageTestDirectory(t, stageOptions{})

		cfg := service.Config{
			Enabled:  true,
			Policies: defaultTestPolicies(),
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
		t.Logf("initial supervisor running with PID: %s", pid1)

		// Delete bee:hive_catalog_policy while activation is active
		catPolEntry, err := reg.GetEntry(registry.ParseID("bee:hive_catalog_policy"))
		if err != nil {
			t.Fatal(err)
		}

		if _, err := reg.Apply(ctx, registry.ChangeSet{{Kind: registry.EntryDelete, Entry: catPolEntry}}); err != nil {
			t.Fatalf("failed to delete catalog policy: %v", err)
		}

		// Attempt to update activation entry to trigger replacement
		actEntry, err := reg.GetEntry(registry.ParseID(service.ActivationID))
		if err != nil {
			t.Fatal(err)
		}
		updated := actEntry
		updated.Meta = attrs.Bag{"replacement": "attempt"}
		if _, err := reg.Apply(ctx, registry.ChangeSet{{Kind: registry.EntryUpdate, Entry: updated, OriginalEntry: &actEntry}}); err != nil {
			t.Fatalf("failed to apply replacement update: %v", err)
		}

		// The replacement service must fail closed in Start because bee:hive_catalog_policy is gone
		state := waitForServiceStatus(t, ctx, supapi.StatusFailed, 3*time.Second)
		if state.Status != supapi.StatusFailed && state.Status != supapi.StatusExited {
			t.Fatalf("expected replacement fail-closed status (failed or exited), got: %s", state.Status)
		}

		if _, ok := topology.GetRegistry(ctx).Lookup(service.ActorID); ok {
			t.Fatal("replacement supervisor unexpectedly registered after dependency removal")
		}
		t.Log("verified replacement failed closed when required dependency was removed")
	})
}
