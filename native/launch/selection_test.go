//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package launch

import (
	"context"
	"io"
	"os"
	"strings"
	"testing"

	"github.com/wippyai/bee/native/client/hive"
	app "github.com/wippyai/runtime/cmd/app"
)

func TestExplicitSelectionDoesNotFallBackToDefaults(t *testing.T) {
	id := strings.Repeat("a", 32)
	for _, pair := range [][2]string{{"", ""}, {id, ""}, {"", id}, {id, "x"}, {id, strings.ToUpper(id)}} {
		if _, err := parseSelection(pair[0], pair[1]); err == nil {
			t.Fatalf("accepted ambiguous or invalid selection: %q", pair)
		}
	}
	got, err := parseSelection(id, strings.Repeat("b", 32))
	if err != nil || got.Workspace != id {
		t.Fatal(got, err)
	}
}

func TestExplicitSelectionAndListNeverRunOwnerForAbsentBee(t *testing.T) {
	id := strings.Repeat("a", 32)
	for _, args := range [][]string{{"desktops"}, {"attach", id, id}, {"observe", id, id}, {"client"}} {
		t.Run(args[0], func(t *testing.T) {
			state := t.TempDir()
			launcher, err := NewLauncher(Client{Command: "bee", Mode: hive.Control, Stdin: os.Stdin, Stdout: io.Discard}, "bee-owner", func(context.Context, app.LaunchRequest) (app.OwnerResources, error) {
				t.Fatal("explicit client command prepared an owner")
				return app.OwnerResources{}, nil
			})
			if err != nil {
				t.Fatal(err)
			}
			called := false
			err = launcher.Launch(context.Background(), app.LaunchRequest{Command: "bee", Arguments: args, StateDir: state, Directory: state}, func(app.OwnerOptions) error { called = true; return nil })
			if err == nil || called {
				t.Fatal(err, called)
			}
		})
	}
}
