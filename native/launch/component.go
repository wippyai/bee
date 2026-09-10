//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package launch

import (
	"context"
	"errors"
	"strings"

	application "github.com/wippyai/runtime/api/application"
)

// OwnerLauncher maps the explicit start command to the host's retained-owner
// entry. Owner preparation remains inside the runtime's real application lock.
// The owner and its DesktopService are separate host-selected boot components.
// It does not bootstrap an owner for ordinary foreground launches yet.
type OwnerLauncher struct {
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
	if request.Operation != application.RunApplication || request.Command != l.command ||
		len(request.Arguments) == 0 || request.Arguments[0] != "start" {
		return application.LaunchPlan{}, nil
	}
	if request.Base || len(request.Arguments) != 1 {
		return application.LaunchPlan{}, errors.New("bee start requires ordinary startup with no extra arguments")
	}
	return application.LaunchPlan{
		Command: l.ownerCommand, Arguments: []string{}, PrepareOwner: l.prepare,
	}, nil
}
