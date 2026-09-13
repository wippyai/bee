// SPDX-License-Identifier: MIT

package docker

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/wippyai/runtime/api/boot"
	bootpkg "github.com/wippyai/runtime/boot"
	luaboot "github.com/wippyai/runtime/boot/components/runtime/lua"
	"github.com/wippyai/runtime/runtime/lua/code"
	"go.uber.org/zap"
)

func TestConfiguredComponentOfflineLifecycle(t *testing.T) {
	// Neither the selected socket nor an ambient Docker host is contacted.
	// An invalid ambient host would also make client.FromEnv fail construction.
	t.Setenv("DOCKER_HOST", "://invalid")
	t.Setenv("DOCKER_TLS_VERIFY", "1")
	t.Setenv("DOCKER_CERT_PATH", filepath.Join(t.TempDir(), "absent-certs"))
	ctx, err := bootpkg.NewBootstrapContext(zap.NewNop(), boot.NewConfig(boot.WithSection("bee", map[string]any{
		"docker.host":      "unix://" + filepath.Join(t.TempDir(), "absent.sock"),
		"docker.reference": "local:docker",
	})))
	if err != nil {
		t.Fatal(err)
	}
	manager, err := code.NewCodeManager(zap.NewNop(), nil, code.Config{})
	if err != nil {
		t.Fatal(err)
	}
	ctx = luaboot.SetCodeManager(ctx, manager)
	component := ConfiguredComponent()
	for range 2 {
		if _, err := component.Load(ctx); err != nil {
			t.Fatalf("offline module registration: %v", err)
		}
	}
	if defs := manager.GetModuleDefs(); len(defs) != 1 || defs[0].Name != "docker_pty" {
		t.Fatalf("registered definitions = %v", defs)
	}
	for range 2 {
		if err := component.(boot.Stopper).Stop(ctx); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := component.Load(ctx); err == nil {
		t.Fatal("stopped component accepted another load")
	}
}

func TestConfiguredComponentRequiresExplicitLocalBinding(t *testing.T) {
	for name, section := range map[string]map[string]any{
		"missing":                      {},
		"ambient host is insufficient": {"docker.reference": "local:docker"},
		"relative socket":              {"docker.reference": "local:docker", "docker.host": "unix://relative.sock"},
		"remote daemon":                {"docker.reference": "local:docker", "docker.host": "tcp://example.com:2375"},
		"missing reference":            {"docker.host": "unix:///absent.sock"},
		"wrong host type":              {"docker.reference": "local:docker", "docker.host": true},
	} {
		t.Run(name, func(t *testing.T) {
			t.Setenv("DOCKER_HOST", "unix:///ambient.sock")
			ctx, err := bootpkg.NewBootstrapContext(zap.NewNop(), boot.NewConfig(boot.WithSection("bee", section)))
			if err != nil {
				t.Fatal(err)
			}
			manager, err := code.NewCodeManager(zap.NewNop(), nil, code.Config{})
			if err != nil {
				t.Fatal(err)
			}
			ctx = luaboot.SetCodeManager(ctx, manager)
			component := ConfiguredComponent()
			if _, err := component.Load(ctx); err == nil {
				t.Fatal("invalid host binding accepted")
			}
			if len(manager.GetModuleDefs()) != 0 {
				t.Fatal("invalid host binding published a module")
			}
			if err := component.(boot.Stopper).Stop(context.Background()); err != nil {
				t.Fatal(err)
			}
		})
	}
}
