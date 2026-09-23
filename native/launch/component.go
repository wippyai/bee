// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/wippyai/bee/native/hookpost"
	"github.com/wippyai/runtime/api/boot"
	envapi "github.com/wippyai/runtime/api/env"
	"github.com/wippyai/runtime/api/registry"
	bootsystem "github.com/wippyai/runtime/boot/components/system"
	app "github.com/wippyai/runtime/cmd/app"
)

const (
	ComponentName  boot.Name = "bee.launch"
	StorageID                = "bee.harness.host:environment"
	desktopCommand           = "bee"
	ownerCommand             = "bee-owner"
	ownerArgument            = "start"
	hookArgument             = "hook-post"
)

// Host is both Bee's app.Host and its sole native boot component. The runtime
// calls Plan before it opens state, while Load registers the one read-only host
// environment storage needed by native integrations.
type Host struct {
	defaultRoot string
	// ownerState is the state directory selected for a retained owner launch. It
	// is set during planning so Load can add the owner's enrollment publisher.
	ownerState string
	components []boot.Component
	resolver   hostResolver
	initErr    error
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
	// A harness hook process carries a token the gateway authorizes. It posts one
	// event within the hook deadline and never selects a project, opens state or
	// reaches the retained owner.
	if launch.Op == app.OpRun && launch.Command == desktopCommand && len(launch.Args) > 0 && launch.Args[0] == hookArgument {
		if len(launch.Args) != 5 {
			return app.Plan{}, errors.New("hook-post: expected ENDPOINT ACTION_ID TOKEN_ENV_OR_FILE EVENT")
		}
		args := launch.Args
		return app.Plan{Run: func(ctx context.Context) error {
			return hookpost.Run(ctx, os.Stdin, args[1], args[2], args[3], args[4])
		}}, nil
	}
	desktop := launch.Op == app.OpRun && launch.Command == desktopCommand
	if desktop && len(launch.Args) > 0 && helpWords[launch.Args[0]] {
		if len(launch.Args) != 1 {
			return app.Plan{}, errors.New("bee help takes no arguments")
		}
		usage := host.usage(launch)
		return app.Plan{Run: func(context.Context) error {
			_, err := io.WriteString(os.Stdout, usage)
			return err
		}}, nil
	}
	owner := desktop && len(launch.Args) > 0 && launch.Args[0] == ownerArgument
	if owner && len(launch.Args) != 1 {
		return app.Plan{}, errors.New("bee start takes no arguments")
	}
	// An explicit application ID keeps the runtime's own entry, which is how
	// recovery and development launches still reach an application directly.
	application := desktop && len(launch.Args) > 0 && strings.Contains(launch.Args[0], ":")
	// Every other ordinary launch of this executable is a client of the retained
	// owner. Its words are decoded before a project is selected, so a malformed
	// invocation reads no state.
	client := desktop && !owner && !application
	var intent clientIntent
	if client {
		parsed, err := parseClientIntent(launch.Args)
		if err != nil {
			return app.Plan{}, err
		}
		intent = parsed
	}
	plan := app.Plan{}
	if !launch.Explicit {
		root := launch.State
		if root == "" {
			root = host.defaultRoot
		}
		selected, err := DefaultProjectStateDir(root, launch.Dir)
		if err != nil {
			return app.Plan{}, err
		}
		plan.DefaultState = selected
	}
	// The retained owner route keeps the runtime's own application start, so it
	// prepares the owner's cluster, desktop bridge and enrollment publisher.
	if owner {
		plan.Command = ownerCommand
		plan.Args = []string{}
		state := launch.State
		if state == "" {
			state = plan.DefaultState
		}
		host.ownerState = state
		plan.Prepare = func(context.Context) (boot.Config, func() error, error) {
			return prepareOwner(state)
		}
		return plan, nil
	}
	// The runtime never opens the client's state for it: the host decides
	// ownership, starts the owner when needed, enrolls this process and joins.
	if client {
		selected := launch
		if selected.State == "" {
			selected.State = plan.DefaultState
		}
		selected.State = resolvePlannedState(selected)
		plan.DefaultState = ""
		plan.Run = func(ctx context.Context) error { return runClientRoute(ctx, selected, intent) }
	}
	return plan, nil
}

// resolvePlannedState makes a host-selected default absolute against the
// invocation's working directory, matching the runtime's own resolution.
func resolvePlannedState(launch app.Launch) string {
	if launch.State == "" || filepath.IsAbs(launch.State) {
		return launch.State
	}
	return filepath.Join(launch.Dir, launch.State)
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

// Start activates the owner's enrollment publisher when this launch is the
// retained owner. The host is itself one of the executable's boot components, so
// it starts the publisher directly; the cluster it depends on is already up by
// the time Start runs.
func (host *Host) Start(ctx context.Context) error {
	if host.initErr != nil {
		return host.initErr
	}
	if host.ownerState == "" {
		return nil
	}
	execution, err := ensureExecution(ownerDirectory(host.ownerState))
	if err != nil {
		return err
	}
	components, err := ownerComponents(host.ownerState, execution)
	if err != nil {
		return err
	}
	host.components = components
	for _, component := range components {
		if starter, ok := component.(boot.Starter); ok {
			if err := starter.Start(ctx); err != nil {
				return err
			}
		}
	}
	return nil
}

// Stop releases the owner components this host started.
func (host *Host) Stop(ctx context.Context) error {
	var result error
	for _, component := range host.components {
		if stopper, ok := component.(boot.Stopper); ok {
			result = errors.Join(result, stopper.Stop(ctx))
		}
	}
	host.components = nil
	return result
}

func registryID() registry.ID { return registry.ParseID(StorageID) }
