// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"errors"
	"path/filepath"
	"testing"

	"github.com/wippyai/runtime/api/boot"
	envapi "github.com/wippyai/runtime/api/env"
	"github.com/wippyai/runtime/api/registry"
	bootpkg "github.com/wippyai/runtime/boot"
	bootsystem "github.com/wippyai/runtime/boot/components/system"
	app "github.com/wippyai/runtime/cmd/app"
	envsystem "github.com/wippyai/runtime/system/env"
	"go.uber.org/zap"
)

func TestPlanUsesProjectDefaultAndLeavesExplicitStateAlone(t *testing.T) {
	root := filepath.Join(t.TempDir(), "state")
	project := makeProject(t)
	host, err := newHost(root, systemHostResolver())
	if err != nil {
		t.Fatal(err)
	}

	plan, err := host.Plan(context.Background(), app.Launch{Dir: project, State: root})
	if err != nil {
		t.Fatal(err)
	}
	want, err := ProjectStateDir(root, project)
	if err != nil {
		t.Fatal(err)
	}
	if plan.DefaultState != want {
		t.Fatalf("default state = %q, want %q", plan.DefaultState, want)
	}

	explicit := filepath.Join(t.TempDir(), "chosen")
	plan, err = host.Plan(context.Background(), app.Launch{Dir: project, State: explicit, Explicit: true})
	if err != nil {
		t.Fatal(err)
	}
	if plan.DefaultState != "" {
		t.Fatalf("explicit launch received default state %q", plan.DefaultState)
	}
}

func TestPlanMapsOnlyExplicitOwnerStart(t *testing.T) {
	host, err := newHost(filepath.Join(t.TempDir(), "state"), systemHostResolver())
	if err != nil {
		t.Fatal(err)
	}
	project := makeProject(t)
	plan, err := host.Plan(context.Background(), app.Launch{
		Dir: project, State: t.TempDir(), Explicit: true, Op: app.OpRun,
		Command: desktopCommand, Args: []string{ownerArgument},
	})
	if err != nil {
		t.Fatal(err)
	}
	if plan.Command != ownerCommand || plan.Args == nil || len(plan.Args) != 0 {
		t.Fatalf("owner plan = command %q args %#v", plan.Command, plan.Args)
	}

	ordinary, err := host.Plan(context.Background(), app.Launch{
		Dir: project, State: t.TempDir(), Explicit: true, Op: app.OpRun,
		Command: desktopCommand, Args: []string{"agent"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if ordinary.Command != "" || ordinary.Args != nil {
		t.Fatalf("ordinary launch was remapped: command %q args %#v", ordinary.Command, ordinary.Args)
	}

	if _, err := host.Plan(context.Background(), app.Launch{
		Dir: project, State: t.TempDir(), Explicit: true, Op: app.OpRun,
		Command: desktopCommand, Args: []string{ownerArgument, "extra"},
	}); err == nil {
		t.Fatal("owner start accepted extra arguments")
	}
}

func TestHostIsOneBootComponentAndHost(t *testing.T) {
	host, err := newHost(filepath.Join(t.TempDir(), "state"), systemHostResolver())
	if err != nil {
		t.Fatal(err)
	}
	var _ boot.Component = host
	var _ app.Host = host
	if host.Name() != ComponentName {
		t.Fatalf("host name = %q", host.Name())
	}
	if len(host.DependsOn()) != 1 || host.DependsOn()[0] != bootsystem.EnvironmentName {
		t.Fatalf("host dependencies = %v", host.DependsOn())
	}
}

func TestHostRegistersReadOnlyEnvironment(t *testing.T) {
	root := t.TempDir()
	resolver := hostResolver{
		lookPath: func(name string) (string, error) {
			if name == "example-tool" {
				return filepath.Join(root, "bin", name), nil
			}
			return "", errors.New("not found")
		},
		homeDir:    func() (string, error) { return filepath.Join(root, "home"), nil },
		getwd:      func() (string, error) { return filepath.Join(root, "work"), nil },
		executable: func() (string, error) { return filepath.Join(root, "bin", "bee"), nil },
	}
	host, err := newHost(filepath.Join(root, "state"), resolver)
	if err != nil {
		t.Fatal(err)
	}
	ctx, err := bootpkg.NewBootstrapContext(zap.NewNop(), boot.NewConfig())
	if err != nil {
		t.Fatal(err)
	}
	environment := boot.New(boot.P{Name: bootsystem.EnvironmentName, Load: func(ctx context.Context) (context.Context, error) {
		return envapi.WithRegistry(ctx, envsystem.NewRegistry(nil, zap.NewNop())), nil
	}})
	loader, err := bootpkg.NewLoader(host, environment)
	if err != nil {
		t.Fatal(err)
	}
	ctx, err = loader.Load(ctx)
	if err != nil {
		t.Fatal(err)
	}
	environmentRegistry := envapi.GetRegistry(ctx)
	if environmentRegistry == nil {
		t.Fatal("environment registry missing")
	}
	storage, err := environmentRegistry.GetStorage(ctx, registry.ParseID(StorageID))
	if err != nil {
		t.Fatal(err)
	}
	if got, err := storage.Get(ctx, "example-tool"); err != nil || got != filepath.Join(root, "bin", "example-tool") {
		t.Fatalf("PATH lookup = %q, %v", got, err)
	}
	if _, err := storage.Get(ctx, filepath.Join(root, "bin", "example-tool")); !errors.Is(err, envapi.ErrVariableNotFound) {
		t.Fatalf("absolute lookup error = %v", err)
	}
	if err := storage.Set(ctx, "example-tool", "other"); err == nil {
		t.Fatal("read-only storage accepted Set")
	}
}
