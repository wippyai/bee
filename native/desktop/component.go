//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT

// Package desktop is Bee's compiled application composition. It installs the
// existing owner, Hive service, client launcher and native I/O module together.
package desktop

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"time"

	"github.com/wippyai/bee/native/client/hive"
	"github.com/wippyai/bee/native/harnesshost"
	"github.com/wippyai/bee/native/hive/localowner"
	"github.com/wippyai/bee/native/hookpost"
	"github.com/wippyai/bee/native/ioevents"
	launchpkg "github.com/wippyai/bee/native/launch"
	"github.com/wippyai/runtime/api/boot"
	"github.com/wippyai/runtime/boot/components/core"
	"github.com/wippyai/runtime/boot/components/dispatchers"
	luaboot "github.com/wippyai/runtime/boot/components/runtime/lua"
	bootsystem "github.com/wippyai/runtime/boot/components/system"
	app "github.com/wippyai/runtime/cmd/app"
)

// Options are selected by the compiled host, never registry activation metadata.
// Node names this same-machine mesh; external Hive enrollment remains separate.
type Options struct {
	Node            string
	Lifetime        time.Duration
	Application     string
	HiveDirectory   string
	ConfigDirectory string
}

type Host struct {
	launcher *launchpkg.OwnerLauncher
	owner    *localowner.Component
	desktop  boot.Component
	events   boot.Component
	hostenv  boot.Component
	initErr  error
}

func New(options Options) (*Host, error) {
	owner, err := localowner.New(localowner.Options{
		Node: options.Node, Lifetime: options.Lifetime,
		HiveDirectory: options.HiveDirectory, ConfigDirectory: options.ConfigDirectory,
	})
	if err != nil {
		return nil, err
	}
	desktop, err := owner.DesktopService([]string{
		"bee:hive_supervisor_policy", "bee:hive_catalog_policy", "bee:hive_exposure_policy",
		"bee:hive_dispatch_policy", "bee:hive_names_policy", "bee:hive_execute_policy",
		"bee.hive.desktop:host_policy",
	}, options.Application)
	if err != nil {
		return nil, err
	}
	launcher, err := launchpkg.NewLauncher(launchpkg.Client{Command: "bee", Mode: hive.Control, Stdin: os.Stdin, Stdout: os.Stdout}, "bee-owner", owner.PrepareProjectOwner)
	if err != nil {
		return nil, err
	}
	return &Host{
		launcher: launcher, owner: owner, desktop: desktop,
		events: ioevents.Component(), hostenv: harnesshost.Component(),
	}, nil
}

// Component is the single factory consumed by Wippy Builder. It returns the
// concrete host so the builder can name it as the executable's Host as well as
// list it among the components. Ordinary fresh desktops start empty;
// applications remain owned by the retained supervisor.
func Component() *Host {
	node, err := os.Hostname()
	if err != nil {
		return &Host{initErr: err}
	}
	root, err := os.UserConfigDir()
	if err != nil {
		return &Host{initErr: err}
	}
	host, err := New(Options{
		Node: node, Lifetime: 30 * 24 * time.Hour,
		HiveDirectory:   filepath.Join(root, "bee", "local-hive"),
		ConfigDirectory: filepath.Join(root, "bee"),
	})
	if err != nil {
		return &Host{initErr: err}
	}
	return host
}

func (*Host) Name() string { return "bee.native" }
func (*Host) DependsOn() []string {
	return []string{"cluster", core.SupervisorName, luaboot.EngineName, dispatchers.DispatcherName, bootsystem.EnvironmentName}
}

// Plan decides one invocation before the runner opens state. It selects the
// project's state, hands the retained-owner start and the client routes to the
// launcher, and runs the hook command as a plan that never touches state.
func (h *Host) Plan(ctx context.Context, launch app.Launch) (app.Plan, error) {
	if h.initErr != nil {
		return app.Plan{}, h.initErr
	}
	// Hook processes carry a token which the gateway must authorize. They never
	// enter owner startup, project canonicalization or application state.
	if launch.Op == app.OpRun && launch.Command == "bee" &&
		len(launch.Args) > 0 && launch.Args[0] == "hook-post" {
		if len(launch.Args) != 5 {
			return app.Plan{}, errors.New("hook-post: expected ENDPOINT ACTION_ID TOKEN_ENV EVENT")
		}
		args := launch.Args
		return app.Plan{Run: func(ctx context.Context) error {
			return hookpost.Run(ctx, os.Stdin, args[1], args[2], args[3], args[4])
		}}, nil
	}
	// Every stateful operation selects the same project state. The runtime still
	// owns the operation itself; this host only decides which state it targets.
	selected, err := h.selectProject(launch)
	if err != nil {
		return app.Plan{}, err
	}
	plan, err := h.launcher.Plan(ctx, selected)
	if err != nil {
		return app.Plan{}, err
	}
	// The model applies Plan.State to the launch, so the project state this host
	// selected must travel in the plan rather than only in the forwarded launch.
	if selected.State != launch.State {
		plan.State = selected.State
	}
	return plan, nil
}

// selectProject gives each canonical launch folder one runtime state directory
// under the state the model resolved for this executable. The model's default
// state for the name "bee" is exactly this host's state root, so the host does
// not compute a second default. A launch that selected state explicitly keeps
// it, and state created by earlier Bee versions stays bound to the root.
func (h *Host) selectProject(launch app.Launch) (app.Launch, error) {
	if launch.Explicit || !filepath.IsAbs(launch.Dir) {
		return launch, nil
	}
	selected, err := launchpkg.CanonicalProject(launch)
	if err != nil {
		return launch, err
	}
	state, err := launchpkg.DefaultProjectStateDir(selected.State, selected.Dir)
	if err != nil {
		return launch, err
	}
	selected.State = state
	return selected, nil
}
func (h *Host) Load(ctx context.Context) (context.Context, error) {
	if h.initErr != nil {
		return ctx, h.initErr
	}
	var err error
	ctx, err = h.hostenv.Load(ctx)
	if err != nil {
		return ctx, err
	}
	ctx, err = h.owner.Load(ctx)
	if err != nil {
		return ctx, err
	}
	ctx, err = h.desktop.Load(ctx)
	if err != nil {
		return ctx, err
	}
	return h.events.Load(ctx)
}
func (h *Host) Start(ctx context.Context) error {
	if h.initErr != nil {
		return h.initErr
	}
	return h.owner.Start(ctx)
}
func (h *Host) Stop(ctx context.Context) error {
	if h.initErr != nil {
		return nil
	}
	return errors.Join(h.events.(boot.Stopper).Stop(ctx), h.owner.Stop(ctx))
}
