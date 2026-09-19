//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package launch

import (
	"context"
	"errors"
	"strings"

	"github.com/wippyai/bee/native/client/hive"
	"github.com/wippyai/runtime/api/boot"
	app "github.com/wippyai/runtime/cmd/app"
)

// OwnerLauncher maps the explicit start command to the host's retained-owner
// entry. Owner preparation remains inside the runtime's real application lock.
// The owner and its DesktopService are separate host-selected boot components.
// NewLauncher additionally selects automatic foreground owner/client startup.
type OwnerLauncher struct {
	client       *Client
	command      string
	ownerCommand string
	prepare      func(context.Context, app.Launch) (boot.Config, func() error, error)
}

func NewOwnerLauncher(command, ownerCommand string, prepare func(context.Context, app.Launch) (boot.Config, func() error, error)) (*OwnerLauncher, error) {
	if command == "" || ownerCommand == "" || command == ownerCommand ||
		strings.ContainsAny(command+ownerCommand, " \t\r\n") || prepare == nil {
		return nil, errors.New("invalid retained owner launch configuration")
	}
	return &OwnerLauncher{command: command, ownerCommand: ownerCommand, prepare: prepare}, nil
}

// NewLauncher enables ordinary foreground startup plus explicit headless start.
// One compiled component owns both routes; the runtime's own verbs stay with
// the runtime.
func NewLauncher(client Client, ownerCommand string, prepare func(context.Context, app.Launch) (boot.Config, func() error, error)) (*OwnerLauncher, error) {
	launcher, err := NewOwnerLauncher(client.Command, ownerCommand, prepare)
	if err != nil {
		return nil, err
	}
	launcher.client = &client
	return launcher, nil
}

func (*OwnerLauncher) Name() string                                      { return "bee.launch" }
func (*OwnerLauncher) DependsOn() []string                               { return nil }
func (*OwnerLauncher) Load(ctx context.Context) (context.Context, error) { return ctx, nil }

// Plan decides what one invocation does before the runner touches state. Only
// an ordinary run of this executable's command is handled here; every reserved
// verb keeps the runtime's own behavior.
func (l *OwnerLauncher) Plan(ctx context.Context, launch app.Launch) (app.Plan, error) {
	if ctx == nil {
		return app.Plan{}, errors.New("owner launch requires a context")
	}
	if err := ctx.Err(); err != nil {
		return app.Plan{}, err
	}
	if launch.Op != app.OpRun || launch.Command != l.command {
		return app.Plan{}, nil
	}
	if len(launch.Args) > 0 && launch.Args[0] == "start" {
		if len(launch.Args) != 1 {
			return app.Plan{}, errors.New("bee start requires ordinary startup with no extra arguments")
		}
		// The retained owner boots the runtime under the real state lock. Its
		// preparation is the host preparation the runtime calls under that lock.
		selected := launch
		return app.Plan{
			Command: l.ownerCommand,
			Args:    []string{},
			Prepare: func(ctx context.Context) (boot.Config, func() error, error) {
				return l.prepare(ctx, selected)
			},
		}, nil
	}
	if l.client == nil {
		return app.Plan{}, nil
	}
	selected, handled, err := l.selectClient(launch)
	if err != nil || !handled {
		return app.Plan{}, err
	}
	// The owner child starts empty. Exactly this foreground session submits the
	// command after admission; spawning the owner must not execute it.
	startup := launch
	startup.Args = nil
	if selected.listing {
		return app.Plan{Run: func(ctx context.Context) error { return selected.list(ctx, startup) }}, nil
	}
	return app.Plan{Run: func(ctx context.Context) error { return selected.Run(ctx, startup) }}, nil
}

// selectClient maps one ordinary invocation onto this host's display client.
// An unhandled request keeps the runtime's own application entry, which is how
// an explicit application ID still reaches recovery and development launches.
func (l *OwnerLauncher) selectClient(launch app.Launch) (clientSelection, bool, error) {
	selected := clientSelection{Client: *l.client}
	if len(launch.Args) == 0 {
		return selected, true, nil
	}
	display := launch.Args[0] == "client"
	observe := launch.Args[0] == "observe"
	attach := launch.Args[0] == "attach"
	selected.listing = launch.Args[0] == "desktops"
	if selected.listing && len(launch.Args) != 1 {
		return selected, false, errors.New("bee desktops takes no arguments")
	}
	if observe || attach || display {
		if len(launch.Args) == 3 {
			selection, err := parseSelection(launch.Args[1], launch.Args[2])
			if err != nil {
				return selected, false, err
			}
			selected.Selection = selection
		} else if attach || len(launch.Args) != 1 {
			return selected, false, errors.New("bee attach requires WORKSPACE DISPLAY; bee observe/client takes no application arguments or one WORKSPACE DISPLAY pair")
		}
		selected.AttachOnly = display
		selected.Mode = hive.Control
		if observe {
			selected.Mode = hive.Observe
		}
		selected.Launch = nil
		return selected, true, nil
	}
	if selected.listing {
		return selected, true, nil
	}
	// Explicit application IDs retain their existing recovery/development
	// entry. Named handlers resolve only through the retained owner.
	if strings.Contains(launch.Args[0], ":") {
		return selected, false, nil
	}
	command := hive.DesktopCommand{Name: launch.Args[0], Arguments: append([]string{}, launch.Args[1:]...)}
	if !command.Valid() {
		return selected, false, errors.New("invalid Bee command arguments")
	}
	selected.Launch = &command
	return selected, true, nil
}

type clientSelection struct {
	Client
	listing bool
}
