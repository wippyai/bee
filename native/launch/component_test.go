//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package launch

import (
	"context"
	"io"
	"os"
	"testing"

	"github.com/wippyai/bee/native/client/hive"
	app "github.com/wippyai/runtime/cmd/app"
)

func TestStartRouteDefersPreparationToRuntimeOwner(t *testing.T) {
	calls := 0
	launcher, err := NewOwnerLauncher("bee", "retained-owner", func(context.Context, app.LaunchRequest) (app.OwnerResources, error) {
		calls++
		return app.OwnerResources{}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	request := app.LaunchRequest{Command: "bee", Arguments: []string{"start"}, StateDir: t.TempDir()}
	called := false
	err = launcher.Launch(context.Background(), request, func(options app.OwnerOptions) error {
		called = true
		if options.Command != "retained-owner" || options.Arguments == nil || len(options.Arguments) != 0 || options.Prepare == nil || calls != 0 {
			t.Fatalf("wrong owner options: %+v calls=%d", options, calls)
		}
		if _, err := options.Prepare(context.Background()); err != nil || calls != 1 {
			t.Fatal(err, calls)
		}
		return nil
	})
	if err != nil || !called {
		t.Fatal(err, called)
	}
}

func TestStartBusyProbesInsteadOfTakingAnotherLock(t *testing.T) {
	launcher, err := NewOwnerLauncher("bee", "retained-owner", func(context.Context, app.LaunchRequest) (app.OwnerResources, error) {
		return app.OwnerResources{}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	// No native descriptor exists, so the required supervisor probe fails. The
	// assertion is that Launch invoked the runtime runner exactly once and did
	// not create a second locking mechanism in Bee.
	calls := 0
	err = launcher.Launch(context.Background(), app.LaunchRequest{Command: "bee", Arguments: []string{"start"}, StateDir: t.TempDir()}, func(app.OwnerOptions) error {
		calls++
		return app.ErrBusy
	})
	if calls != 1 || err == nil {
		t.Fatal(calls, err)
	}
}

func TestObserveRefusesAbsentBeeWithoutStartingOwner(t *testing.T) {
	state := t.TempDir()
	launcher, err := NewLauncher(Client{Command: "bee", Mode: hive.Control, Stdin: os.Stdin, Stdout: io.Discard}, "bee-owner",
		func(context.Context, app.LaunchRequest) (app.OwnerResources, error) {
			t.Fatal("observation prepared a new Bee")
			return app.OwnerResources{}, nil
		})
	if err != nil {
		t.Fatal(err)
	}
	called := false
	err = launcher.Launch(context.Background(), app.LaunchRequest{Command: "bee", Arguments: []string{"observe"}, StateDir: state, Directory: state}, func(app.OwnerOptions) error {
		called = true
		return nil
	})
	if err == nil || called {
		t.Fatal(err, called)
	}
}
