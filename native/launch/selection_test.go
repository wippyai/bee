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
	"github.com/wippyai/runtime/api/boot"
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
			launcher, err := NewLauncher(Client{Command: "bee", Mode: hive.Control, Stdin: os.Stdin, Stdout: io.Discard}, "bee-owner", func(context.Context, app.Launch) (boot.Config, func() error, error) {
				t.Fatal("explicit client command prepared an owner")
				return nil, nil, nil
			})
			if err != nil {
				t.Fatal(err)
			}
			plan, err := launcher.Plan(context.Background(), app.Launch{
				Op: app.OpRun, Command: "bee", Args: args, State: state, Dir: state,
			})
			if err != nil || plan.Prepare != nil || plan.Run == nil || plan.Command != "" {
				t.Fatal(err, plan)
			}
			// The model keeps the decision and the work separate: the explicit
			// client route runs through Plan.Run and must refuse an absent Bee.
			if err := plan.Run(context.Background()); err == nil {
				t.Fatal("explicit client command accepted an absent Bee")
			}
			entries, readErr := os.ReadDir(state)
			if readErr != nil {
				t.Fatal(readErr)
			}
			if len(entries) != 0 {
				t.Fatal("explicit client command created state", entries)
			}
		})
	}
}
