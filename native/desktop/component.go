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
	"github.com/wippyai/bee/native/launch"
	application "github.com/wippyai/runtime/api/application"
	"github.com/wippyai/runtime/api/boot"
	"github.com/wippyai/runtime/boot/components/core"
	"github.com/wippyai/runtime/boot/components/dispatchers"
	luaboot "github.com/wippyai/runtime/boot/components/runtime/lua"
	bootsystem "github.com/wippyai/runtime/boot/components/system"
)

// Options are selected by the compiled host, never registry activation metadata.
// Node names this same-machine mesh; external Hive enrollment remains separate.
type Options struct {
	Node        string
	Lifetime    time.Duration
	Application string
	// StateRoot holds one runtime state directory per canonical launch folder.
	// Empty keeps the state directory the request already selected.
	StateRoot       string
	HiveDirectory   string
	ConfigDirectory string
}

type Host struct {
	launcher  *launch.OwnerLauncher
	owner     *localowner.Component
	desktop   boot.Component
	events    boot.Component
	hostenv   boot.Component
	stateRoot string
	initErr   error
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
	launcher, err := launch.NewLauncher(launch.Client{Command: "bee", Mode: hive.Control, Stdin: os.Stdin, Stdout: os.Stdout}, "bee-owner", owner.PrepareProjectOwner)
	if err != nil {
		return nil, err
	}
	return &Host{
		launcher: launcher, owner: owner, desktop: desktop,
		events: ioevents.Component(), hostenv: harnesshost.Component(),
		stateRoot: options.StateRoot,
	}, nil
}

// Component is the single factory consumed by Wippy Builder. Ordinary fresh
// desktops start empty; applications remain owned by the retained supervisor.
func Component() boot.Component {
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
		StateRoot:       filepath.Join(root, "bee"),
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
func (h *Host) PrepareLaunch(ctx context.Context, request application.LaunchRequest) (application.LaunchPlan, error) {
	if h.initErr != nil {
		return application.LaunchPlan{}, h.initErr
	}
	// Hook processes carry a token which the gateway must authorize. They never
	// enter owner startup, project canonicalization or application state.
	if request.Operation == application.RunApplication && request.Command == "bee" &&
		len(request.Arguments) > 0 && request.Arguments[0] == "hook-post" {
		if len(request.Arguments) != 5 {
			return application.LaunchPlan{}, errors.New("hook-post: expected ENDPOINT ACTION_ID TOKEN_ENV EVENT")
		}
		return application.LaunchPlan{Handled: true},
			hookpost.Run(ctx, os.Stdin, request.Arguments[1], request.Arguments[2], request.Arguments[3], request.Arguments[4])
	}
	selected, err := h.selectProject(request)
	if err != nil {
		return application.LaunchPlan{}, err
	}
	plan, err := h.launcher.PrepareLaunch(ctx, selected)
	if err != nil {
		return plan, err
	}
	if plan.StateDir == "" && selected.StateDir != request.StateDir {
		plan.StateDir = selected.StateDir
	}
	if request.Operation == application.RunApplication && !request.Base && !plan.Handled {
		// Code follows this executable; authored registry history stays with the
		// selected state. Recovery and runtime/update commands keep their policy.
		plan.EmbeddedBaseline = true
	}
	return plan, nil
}

// selectProject gives each canonical launch folder one runtime state directory
// under the host's state root. A request that selected state explicitly keeps
// it, and state created by earlier Bee versions stays bound to the root.
func (h *Host) selectProject(request application.LaunchRequest) (application.LaunchRequest, error) {
	if h.stateRoot == "" || request.ExplicitState || !filepath.IsAbs(request.Directory) {
		return request, nil
	}
	selected, err := launch.CanonicalProject(request)
	if err != nil {
		return request, err
	}
	state, err := launch.DefaultProjectStateDir(h.stateRoot, selected.Directory)
	if err != nil {
		return request, err
	}
	selected.StateDir = state
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
