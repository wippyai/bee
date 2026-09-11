//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package launch

import (
	"context"
	"errors"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/wippyai/bee/native/client/hive"
	"github.com/wippyai/bee/native/client/session"
	"github.com/wippyai/bee/native/hive/rendezvous"
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
	prepare      func(context.Context, app.LaunchRequest) (app.OwnerResources, error)
}

func NewOwnerLauncher(command, ownerCommand string, prepare func(context.Context, app.LaunchRequest) (app.OwnerResources, error)) (*OwnerLauncher, error) {
	if command == "" || ownerCommand == "" || command == ownerCommand ||
		strings.ContainsAny(command+ownerCommand, " \t\r\n") || prepare == nil {
		return nil, errors.New("invalid retained owner launch configuration")
	}
	return &OwnerLauncher{command: command, ownerCommand: ownerCommand, prepare: prepare}, nil
}

// NewLauncher enables ordinary foreground startup plus explicit headless start.
// One compiled component owns both routes; runtime/update/base bypass Launch.
func NewLauncher(client Client, ownerCommand string, prepare func(context.Context, app.LaunchRequest) (app.OwnerResources, error)) (*OwnerLauncher, error) {
	launcher, err := NewOwnerLauncher(client.Command, ownerCommand, prepare)
	if err != nil {
		return nil, err
	}
	launcher.client = &client
	return launcher, nil
}

// Launch routes one ordinary Bee invocation. The runtime calls it before it
// opens application state; runOwner is the sole path which can own that state.
func (l *OwnerLauncher) Launch(ctx context.Context, request app.LaunchRequest, runOwner func(app.OwnerOptions) error) error {
	if ctx == nil {
		return errors.New("owner launch requires a context")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if runOwner == nil {
		return errors.New("owner launch requires a runtime owner runner")
	}
	if request.Command != l.command {
		return runOwner(app.OwnerOptions{})
	}
	if len(request.Arguments) == 1 && request.Arguments[0] == "start" {
		return l.start(ctx, request, runOwner)
	}
	if len(request.Arguments) > 0 && request.Arguments[0] == "start" {
		return errors.New("bee start requires ordinary startup with no extra arguments")
	}
	if l.client == nil {
		return runOwner(app.OwnerOptions{})
	}

	selected := *l.client
	clientOnly := len(request.Arguments) > 0 && request.Arguments[0] == "client"
	selected.AttachOnly = clientOnly
	observe := len(request.Arguments) > 0 && request.Arguments[0] == "observe"
	attach := len(request.Arguments) > 0 && request.Arguments[0] == "attach"
	listing := len(request.Arguments) > 0 && request.Arguments[0] == "desktops"
	if listing && len(request.Arguments) != 1 {
		return errors.New("bee desktops takes no arguments")
	}
	if observe || attach || clientOnly {
		if len(request.Arguments) == 3 {
			selection, err := parseSelection(request.Arguments[1], request.Arguments[2])
			if err != nil {
				return err
			}
			selected.Selection = selection
		} else if attach || len(request.Arguments) != 1 {
			return errors.New("bee attach requires WORKSPACE DISPLAY; bee observe/client takes no application arguments or one WORKSPACE DISPLAY pair")
		}
		selected.Mode = hive.Control
		if observe {
			selected.Mode = hive.Observe
		}
		selected.Launch = nil
	}
	if len(request.Arguments) > 0 && !observe && !attach && !listing && !clientOnly {
		// Explicit application IDs retain their existing recovery/development
		// entry. Named handlers resolve only through the retained owner.
		if strings.Contains(request.Arguments[0], ":") {
			return runOwner(app.OwnerOptions{})
		}
		command := hive.DesktopCommand{Name: request.Arguments[0], Arguments: append([]string{}, request.Arguments[1:]...)}
		if !command.Valid() {
			return errors.New("invalid Bee command arguments")
		}
		selected.Launch = &command
	}
	// The owner child starts empty. Exactly this foreground session submits the
	// command after admission; spawning it must not execute the command.
	startup := request
	startup.Arguments = nil
	foreground, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stop()
	if listing {
		return selected.list(foreground, startup)
	}
	return selected.Run(foreground, startup)
}

func (l *OwnerLauncher) start(ctx context.Context, request app.LaunchRequest, runOwner func(app.OwnerOptions) error) error {
	err := runOwner(app.OwnerOptions{
		Command: l.ownerCommand, Arguments: []string{},
		Prepare: func(owner context.Context) (app.OwnerResources, error) {
			return l.prepare(owner, request)
		},
	})
	if !errors.Is(err, app.ErrBusy) {
		return err
	}
	// A competing explicit start never gets a second lock. The elected owner
	// must still prove native readiness through its supervisor.
	return session.Probe(ctx, filepath.Join(request.StateDir, rendezvous.DirectoryName))
}
