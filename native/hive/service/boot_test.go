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

// TestActualNativeListenerStartup checks enabled, disabled and foreign activation.
func TestActualNativeListenerStartup(t *testing.T) {
	for _, mode := range []string{"enabled", "disabled", "foreign"} {
		t.Run(mode, func(t *testing.T) { runActualNativeListener(t, mode) })
	}
}

func runActualNativeListener(t *testing.T, mode string) {
	root := stageTestDirectory(t, stageOptions{
		activationName: map[bool]string{true: "foreign", false: "activation"}[mode == "foreign"],
	})

	ctx, err := bootpkg.NewBootstrapContext(zap.NewNop(), boot.NewConfig())
	if err != nil {
		t.Fatal(err)
	}

	comp, err := service.New(service.Config{Enabled: mode != "disabled", Policies: defaultTestPolicies()})
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
	if mode == "foreign" {
		if loadErr == nil || !strings.Contains(loadErr.Error(), "unapproved activation identity") {
			t.Fatalf("unexpected admission: %v", loadErr)
		}
		return
	}
	if loadErr != nil {
		t.Fatal(loadErr)
	}

	if mode == "disabled" {
		if _, ok := topology.GetRegistry(ctx).Lookup("bee.hive.supervisor"); ok {
			t.Fatal("disabled supervisor registered in topology")
		}
		if _, err := supapi.GetServiceInfo(ctx).GetState(registry.ParseID("bee.hive:activation")); err == nil {
			t.Fatal("disabled service registered in supervisor")
		}
		if clusterapi.GetMembership(ctx) != nil {
			t.Fatal("local boot exposed cluster trust owner")
		}
		return
	}

	// Enabled mode: verify supervisor registration and same-ID replacement
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if p, ok := topology.GetRegistry(ctx).Lookup("bee.hive.supervisor"); ok {
			t.Logf("actual supervisor registered: %s", p)
			entry, err := reg.GetEntry(registry.ParseID(service.ActivationID))
			if err != nil {
				t.Fatal(err)
			}
			if _, err := reg.Apply(ctx, registry.ChangeSet{{Kind: registry.EntryUpdate, Entry: entry, OriginalEntry: &entry}}); err != nil {
				t.Fatal(err)
			}
			until := time.Now().Add(5 * time.Second)
			for time.Now().Before(until) {
				fresh, ok := topology.GetRegistry(ctx).Lookup(service.ActorID)
				if ok && fresh != p {
					t.Logf("replacement supervisor: %s", fresh)
					return
				}
				time.Sleep(10 * time.Millisecond)
			}
			t.Fatal("replacement did not publish a fresh supervisor")
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("actual supervisor did not register")
}
