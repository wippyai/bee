//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package launch

import (
	"context"
	"errors"
	"github.com/wippyai/bee/native/client/hive"
	"github.com/wippyai/bee/native/client/session"
	"github.com/wippyai/bee/native/hive/rendezvous"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	application "github.com/wippyai/runtime/api/application"
)

// OwnerLauncher maps the explicit start command to the host's retained-owner
// entry. Owner preparation remains inside the runtime's real application lock.
// The owner and its DesktopService are separate host-selected boot components.
// NewLauncher additionally selects automatic foreground owner/client startup.
type OwnerLauncher struct {
	client       *Client
	command      string
	ownerCommand string
	prepare      func(context.Context, application.LaunchRequest) (application.OwnerPlan, error)
}

func NewOwnerLauncher(command, ownerCommand string, prepare func(context.Context, application.LaunchRequest) (application.OwnerPlan, error)) (*OwnerLauncher, error) {
	if command == "" || ownerCommand == "" || command == ownerCommand ||
		strings.ContainsAny(command+ownerCommand, " \t\r\n") || prepare == nil {
		return nil, errors.New("invalid retained owner launch configuration")
	}
	return &OwnerLauncher{command: command, ownerCommand: ownerCommand, prepare: prepare}, nil
}

// NewLauncher enables ordinary foreground startup plus explicit headless start.
// One compiled component owns both routes; runtime/update/base remain separate.
func NewLauncher(client Client, ownerCommand string, prepare func(context.Context, application.LaunchRequest) (application.OwnerPlan, error)) (*OwnerLauncher, error) {
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

func (l *OwnerLauncher) PrepareLaunch(ctx context.Context, request application.LaunchRequest) (application.LaunchPlan, error) {
	if ctx == nil {
		return application.LaunchPlan{}, errors.New("owner launch requires a context")
	}
	if err := ctx.Err(); err != nil {
		return application.LaunchPlan{}, err
	}
	if request.Operation != application.RunApplication || request.Command != l.command {
		return application.LaunchPlan{}, nil
	}
	if len(request.Arguments) > 0 && request.Arguments[0] == "start" {
		if request.Base || len(request.Arguments) != 1 {
			return application.LaunchPlan{}, errors.New("bee start requires ordinary startup with no extra arguments")
		}
		return application.LaunchPlan{
			Command: l.ownerCommand, Arguments: []string{}, PrepareOwner: l.prepare,
			Attach: func(ctx context.Context, selected application.LaunchRequest) error {
				return session.Probe(ctx, filepath.Join(selected.StateDir, rendezvous.DirectoryName))
			},
		}, nil
	}
	if l.client == nil || request.Base {
		return application.LaunchPlan{}, nil
	}
	selected, handled, err := l.selectClient(request)
	if err != nil || !handled {
		return application.LaunchPlan{}, err
	}
	// The owner child starts empty. Exactly this foreground session submits the
	// command after admission; spawning the owner must not execute it.
	startup := request
	startup.Arguments = nil
	foreground, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stop()
	if selected.listing {
		return application.LaunchPlan{Handled: true}, selected.list(foreground, startup)
	}
	return application.LaunchPlan{Handled: true}, selected.Run(foreground, startup)
}

// selectClient maps one ordinary invocation onto this host's display client.
// An unhandled request keeps the runtime's own application entry, which is how
// an explicit application ID still reaches recovery and development launches.
func (l *OwnerLauncher) selectClient(request application.LaunchRequest) (clientSelection, bool, error) {
	selected := clientSelection{Client: *l.client}
	if len(request.Arguments) == 0 {
		return selected, true, nil
	}
	display := request.Arguments[0] == "client"
	observe := request.Arguments[0] == "observe"
	attach := request.Arguments[0] == "attach"
	selected.listing = request.Arguments[0] == "desktops"
	if selected.listing && len(request.Arguments) != 1 {
		return selected, false, errors.New("bee desktops takes no arguments")
	}
	if observe || attach || display {
		if len(request.Arguments) == 3 {
			selection, err := parseSelection(request.Arguments[1], request.Arguments[2])
			if err != nil {
				return selected, false, err
			}
			selected.Selection = selection
		} else if attach || len(request.Arguments) != 1 {
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
	if strings.Contains(request.Arguments[0], ":") {
		return selected, false, nil
	}
	command := hive.DesktopCommand{Name: request.Arguments[0], Arguments: append([]string{}, request.Arguments[1:]...)}
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
