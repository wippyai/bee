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
	"github.com/wippyai/bee/native/ioevents"
	"github.com/wippyai/bee/native/launch"
	"github.com/wippyai/runtime/api/boot"
	"github.com/wippyai/runtime/boot/components/core"
	"github.com/wippyai/runtime/boot/components/dispatchers"
	luaboot "github.com/wippyai/runtime/boot/components/runtime/lua"
	app "github.com/wippyai/runtime/cmd/app"
)

// Options are selected by the compiled host, never registry activation metadata.
// Node names this same-machine mesh; external Hive enrollment remains separate.
type Options struct {
	Node          string
	Lifetime      time.Duration
	Application   string
	HiveDirectory string
}

type Host struct {
	launcher *launch.OwnerLauncher
	owner    *localowner.Component
	desktop  boot.Component
	events   boot.Component
	hostenv  boot.Component
	initErr  error
}

func New(options Options) (*Host, error) {
	owner, err := localowner.New(localowner.Options{Node: options.Node, Lifetime: options.Lifetime, HiveDirectory: options.HiveDirectory})
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
	return &Host{launcher: launcher, owner: owner, desktop: desktop, events: ioevents.Component(), hostenv: harnesshost.Component()}, nil
}

// Component is the single factory consumed by Wippy Builder. Ordinary fresh
// desktops start empty; applications remain owned by the retained supervisor.
func Component() *Host {
	node, err := os.Hostname()
	if err != nil {
		return &Host{initErr: err}
	}
	root, err := os.UserConfigDir()
	if err != nil {
		return &Host{initErr: err}
	}
	host, err := New(Options{Node: node, Lifetime: 30 * 24 * time.Hour, HiveDirectory: filepath.Join(root, "bee", "local-hive")})
	if err != nil {
		return &Host{initErr: err}
	}
	return host
}

func (*Host) Name() string { return "bee.native" }
func (*Host) DependsOn() []string {
	return []string{"cluster", core.SupervisorName, luaboot.EngineName, dispatchers.DispatcherName}
}

// Launch is the cmd/app entry selected by Bee's executable. It is deliberately
// separate from boot.Component: runtime launch callbacks do not use components
// as an adapter interface.
func (h *Host) Launch(ctx context.Context, request app.LaunchRequest, runOwner func(app.OwnerOptions) error) error {
	if h.initErr != nil {
		return h.initErr
	}
	selected, err := launch.CanonicalProject(request)
	if err != nil {
		return err
	}
	return h.launcher.Launch(ctx, selected, runOwner)
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
