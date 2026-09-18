// SPDX-License-Identifier: MIT
package harnesshost

import (
	"context"
	"errors"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/wippyai/runtime/api/boot"
	envapi "github.com/wippyai/runtime/api/env"
	"github.com/wippyai/runtime/api/registry"
	bootpkg "github.com/wippyai/runtime/boot"
	bootsystem "github.com/wippyai/runtime/boot/components/system"
	envsystem "github.com/wippyai/runtime/system/env"
	"go.uber.org/zap"
)

func resolver(root string, paths map[string]string) Resolver {
	return Resolver{
		LookPath: func(name string) (string, error) {
			if p, ok := paths[name]; ok {
				return p, nil
			}
			return "", errors.New("not found")
		},
		HomeDir: func() (string, error) { return filepath.Join(root, "home", "test"), nil }, Getwd: func() (string, error) { return filepath.Join(root, "work", "test"), nil },
		Executable: func() (string, error) { return filepath.Join(root, "bin", "bee"), nil },
	}
}
func TestStorageExposesOnlyNonsecretHostPaths(t *testing.T) {
	root := t.TempDir()
	claude := filepath.Join(root, "opt", "bin", "claude")
	s, err := NewStorage(resolver(root, map[string]string{"claude": claude, "relative": "bin/tool"}))
	if err != nil {
		t.Fatal(err)
	}
	for name, want := range map[string]string{"home": filepath.Join(root, "home", "test"), "cwd": filepath.Join(root, "work", "test"), "self": filepath.Join(root, "bin", "bee"), "claude": claude} {
		got, err := s.Get(context.Background(), name)
		if err != nil || got != want {
			t.Fatalf("Get(%q) = %q, %v", name, got, err)
		}
	}
	for _, name := range []string{"missing", "../claude", filepath.Join(root, "usr", "bin", "claude"), ".", "relative"} {
		if _, err := s.Get(context.Background(), name); !errors.Is(err, envapi.ErrVariableNotFound) {
			t.Fatalf("Get(%q) error = %v", name, err)
		}
	}
	if err := s.Set(context.Background(), "claude", "/other"); err == nil {
		t.Fatal("Set succeeded")
	}
	if err := s.Delete(context.Background(), "claude"); err == nil {
		t.Fatal("Delete succeeded")
	}
	all, err := s.List(context.Background())
	if err != nil || len(all) != 3 || all["home"] != filepath.Join(root, "home", "test") || all["cwd"] != filepath.Join(root, "work", "test") || all["self"] != filepath.Join(root, "bin", "bee") {
		t.Fatalf("List() = %#v, %v", all, err)
	}
}
func TestStorageTreatsExecDotAsUnavailable(t *testing.T) {
	r := resolver(t.TempDir(), nil)
	r.LookPath = func(string) (string, error) { return "dot-command", exec.ErrDot }
	s, err := NewStorage(r)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.Get(context.Background(), "claude"); !errors.Is(err, envapi.ErrVariableNotFound) {
		t.Fatalf("Get dot command error = %v", err)
	}
}
func TestComponentRegistersStorageDuringBoot(t *testing.T) {
	ctx, err := bootpkg.NewBootstrapContext(zap.NewNop(), boot.NewConfig())
	if err != nil {
		t.Fatal(err)
	}
	environment := boot.New(boot.P{Name: bootsystem.EnvironmentName, Load: func(ctx context.Context) (context.Context, error) {
		return envapi.WithRegistry(ctx, envsystem.NewRegistry(nil, zap.NewNop())), nil
	}})
	loader, err := bootpkg.NewLoader(Component(), environment)
	if err != nil {
		t.Fatal(err)
	}
	ctx, err = loader.Load(ctx)
	if err != nil {
		t.Fatal(err)
	}
	reg := envapi.GetRegistry(ctx)
	if reg == nil {
		t.Fatal("environment registry missing")
	}
	storage, err := reg.GetStorage(ctx, registry.ParseID(StorageID))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := storage.Get(ctx, "home"); err != nil {
		t.Fatalf("registered host home: %v", err)
	}
}
func TestStorageRefusesIncompleteOrRelativeHostFacts(t *testing.T) {
	_, err := NewStorage(Resolver{})
	if err == nil {
		t.Fatal("incomplete resolver succeeded")
	}
	r := resolver(t.TempDir(), nil)
	r.HomeDir = func() (string, error) { return "relative", nil }
	if _, err := NewStorage(r); err == nil {
		t.Fatal("relative home succeeded")
	}
	r = resolver(t.TempDir(), nil)
	r.Executable = func() (string, error) { return "relative", nil }
	if _, err := NewStorage(r); err == nil {
		t.Fatal("relative executable succeeded")
	}
}
