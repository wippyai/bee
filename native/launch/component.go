// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"errors"
	"os"
	"path/filepath"

	"github.com/wippyai/runtime/api/boot"
	envapi "github.com/wippyai/runtime/api/env"
	"github.com/wippyai/runtime/api/registry"
	bootsystem "github.com/wippyai/runtime/boot/components/system"
	app "github.com/wippyai/runtime/cmd/app"
)

const (
	ComponentName boot.Name = "bee.launch"
	StorageID               = "bee.harness.host:environment"
)

// Host is both Bee's app.Host and its sole native boot component. The runtime
// calls Plan before it opens state, while Load registers the one read-only host
// environment storage needed by native integrations.
type Host struct {
	defaultRoot string
	resolver    hostResolver
	initErr     error
}

// New creates the launch host for a known default Bee state root. It does not
// inspect or create the root.
func New(defaultRoot string) (*Host, error) {
	return newHost(defaultRoot, systemHostResolver())
}

func newHost(defaultRoot string, resolver hostResolver) (*Host, error) {
	if !filepath.IsAbs(defaultRoot) {
		return nil, errors.New("Bee default state root must be absolute")
	}
	return &Host{defaultRoot: filepath.Clean(defaultRoot), resolver: resolver}, nil
}

// Component is the native factory named by wippy.build.json. The returned
// value is also passed to the runtime as app.Host; no second host component is
// needed for environment registration.
func Component() *Host {
	config, err := os.UserConfigDir()
	if err != nil {
		return &Host{initErr: errors.New("resolve Bee config directory: " + err.Error())}
	}
	host, err := New(filepath.Join(config, "bee"))
	if err != nil {
		return &Host{initErr: err}
	}
	return host
}

func (host *Host) Name() string { return ComponentName }

func (host *Host) DependsOn() []string { return []string{bootsystem.EnvironmentName} }

// Plan selects a project-specific default before the runtime opens state.
// Explicit --state remains entirely under the caller's control.
func (host *Host) Plan(ctx context.Context, launch app.Launch) (app.Plan, error) {
	if host.initErr != nil {
		return app.Plan{}, host.initErr
	}
	if ctx == nil {
		return app.Plan{}, errors.New("Bee launch planning requires a context")
	}
	if err := ctx.Err(); err != nil {
		return app.Plan{}, err
	}
	if launch.Explicit {
		return app.Plan{}, nil
	}
	root := launch.State
	if root == "" {
		root = host.defaultRoot
	}
	selected, err := DefaultProjectStateDir(root, launch.Dir)
	if err != nil {
		return app.Plan{}, err
	}
	return app.Plan{DefaultState: selected}, nil
}

func (host *Host) Load(ctx context.Context) (context.Context, error) {
	if host.initErr != nil {
		return ctx, host.initErr
	}
	registry := envapi.GetRegistry(ctx)
	if registry == nil {
		return ctx, errors.New("environment registry is unavailable")
	}
	storage, err := newHostEnvironment(host.resolver)
	if err != nil {
		return ctx, err
	}
	registry.RegisterStorage(registryID(), storage)
	return ctx, nil
}

func registryID() registry.ID { return registry.ParseID(StorageID) }
