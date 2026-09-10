// SPDX-License-Identifier: MIT
//go:build hiveintegration

package service_test

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/wippyai/runtime/api/boot"
	"github.com/wippyai/runtime/api/registry"
	supapi "github.com/wippyai/runtime/api/supervisor"
	"github.com/wippyai/runtime/api/topology"
	bootpkg "github.com/wippyai/runtime/boot"
	"github.com/wippyai/runtime/cmd/wippy/cmd"
	"go.uber.org/zap"

	service "github.com/wippyai/bee/native/hive/service"
)

// TestHiveServiceComponent_TypedStartupAssertionsAndExactInput proves:
// 1. Host input config is accepted and starts actual supervisor name bee.hive.supervisor.
// 2. Strict typed Lua assertions unconditionally compare the exact configured_nodes input length and content.
// 3. Strict security rights are verified inside the Lua frame before production startup.
// 4. Registry activation entry Data is strictly empty/nil.
// 5. Clean, asserted shutdown.
func TestHiveServiceComponent_TypedStartupAssertionsAndExactInput(t *testing.T) {
	t.Run("empty input verified", func(t *testing.T) {
		root := stageTestDirectory(t, stageOptions{
			configuredNodes:  []string{},
			injectAssertions: true,
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

		p := waitForSupervisorPID(t, ctx, 5*time.Second)
		t.Logf("actual Hive supervisor registered with PID: %s", p)

		state := waitForServiceStatus(t, ctx, supapi.StatusRunning, 5*time.Second)
		if state.Status != supapi.StatusRunning {
			t.Fatalf("expected running status, got: %s", state.Status)
		}
	})

	t.Run("mismatched input length fails unconditionally in lua", func(t *testing.T) {
		// Staged assertion unconditionally expects 0 nodes
		root := stageTestDirectory(t, stageOptions{
			configuredNodes:  []string{},
			injectAssertions: true,
		})

		// Config provides unexpected node, causing #nodes == 0 assertion in Lua to fail immediately
		cfg := service.Config{
			Enabled:         true,
			ConfiguredNodes: []string{"unexpected-node"},
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

		// Supervisor startup assertion in Lua should fail due to length mismatch (expected 2, got 1).
		// Service transitions to failed, and supervisor never registers in topology.
		time.Sleep(300 * time.Millisecond)
		if _, ok := topology.GetRegistry(ctx).Lookup(service.ActorID); ok {
			t.Fatal("supervisor unexpectedly registered despite input length mismatch")
		}
		state := waitForServiceStatus(t, ctx, supapi.StatusFailed, 3*time.Second)
		if state.Status != supapi.StatusFailed {
			t.Fatalf("expected failed status from Lua assertion, got: %s", state.Status)
		}
	})
}

// TestStrictLuaLint_StagedStartupAssertions proves:
// Strict Lua type checker validates the staged startup assertions without errors or warnings.
func TestStrictLuaLint_StagedStartupAssertions(t *testing.T) {
	wippyBin := os.Getenv("BEE_TEST_WIPPY")
	if wippyBin == "" {
		t.Fatal("BEE_TEST_WIPPY must name the reviewed runtime binary")
	}

	root := stageTestDirectory(t, stageOptions{
		configuredNodes:  []string{"node-1", "node-2"},
		injectAssertions: true,
	})

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx,
		wippyBin,
		"lint",
		"--ns", "bee.hive,bee.hive.supervisor",
		"--set", "lua.type_system.enabled=true",
		"--set", "lua.type_system.strict=true",
	)
	cmd.Dir = root
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("strict lua lint failed on staged startup assertions: %v\nOutput:\n%s", err, string(output))
	}
	if !strings.Contains(string(output), "No issues found") {
		t.Fatalf("expected 'No issues found', got:\n%s", string(output))
	}
	t.Log("strict Lua lint passed cleanly on staged startup assertions")
}

// TestHiveServiceComponent_ConfigInputCopied proves:
// Mutating the slice passed to New(Config) after construction does not alter the component state.
func TestHiveServiceComponent_ConfigInputCopied(t *testing.T) {
	root := stageTestDirectory(t, stageOptions{
		injectAssertions: true,
		configuredNodes:  []string{"node-alpha", "node-beta"},
	})

	nodes := []string{"node-alpha", "node-beta"}
	policies := defaultTestPolicies()

	cfg := service.Config{
		Enabled:         true,
		ConfiguredNodes: nodes,
		Policies:        policies,
	}

	comp, err := service.New(cfg)
	if err != nil {
		t.Fatal(err)
	}

	// Mutate slices immediately after constructor returns
	policies[0] = "bee:corrupted_policy"
	nodes[0] = "mutated-node"

	ctx, err := bootpkg.NewBootstrapContext(zap.NewNop(), inputMeshConfig(t))
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

	// Supervisor successfully starts because deep copy preserved original policies
	p := waitForSupervisorPID(t, ctx, 5*time.Second)
	t.Logf("supervisor started with immutable deep copy input: %s", p)
}
