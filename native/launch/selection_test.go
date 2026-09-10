//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package launch

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/wippyai/bee/native/client/hive"
	application "github.com/wippyai/runtime/api/application"
)

func TestExplicitSelectionDoesNotFallBackToDefaults(t *testing.T) {
	id := strings.Repeat("a", 32)
	for _, pair := range [][2]string{{"", ""}, {id, ""}, {"", id}, {id, "x"}, {id, strings.ToUpper(id)}} {
		if _, err := parseSelection(pair[0], pair[1]); err == nil {
			t.Fatalf("accepted ambiguous or invalid selection: %q", pair)
		}
	}
	got, err := parseSelection(id, strings.Repeat("b", 32))
	if err != nil || got.Workspace != id || got.Desktop != strings.Repeat("b", 32) {
		t.Fatal(got, err)
	}
}

func TestExplicitSelectionAndListNeverStartAnAbsentBee(t *testing.T) {
	id := strings.Repeat("a", 32)
	for _, args := range [][]string{{"desktops"}, {"attach", id, id}, {"observe", id, id}} {
		t.Run(args[0], func(t *testing.T) {
			state := t.TempDir()
			launcher, err := NewLauncher(Client{Command: "bee", Mode: hive.Control, Stdin: os.Stdin, Stdout: io.Discard}, "bee-owner",
				func(context.Context, application.LaunchRequest) (application.OwnerPlan, error) {
					t.Fatal("explicit client command prepared an owner")
					return application.OwnerPlan{}, nil
				})
			if err != nil {
				t.Fatal(err)
			}
			plan, err := launcher.PrepareLaunch(context.Background(), application.LaunchRequest{
				Operation: application.RunApplication, Command: "bee", Arguments: args, StateDir: state, Directory: state,
			})
			if err == nil || !strings.Contains(err.Error(), "No running Bee") || !plan.Handled {
				t.Fatal(plan, err)
			}
			for _, pattern := range []string{"owner-*.log", "*.db", "hive"} {
				paths, err := filepath.Glob(filepath.Join(state, pattern))
				if err != nil || len(paths) != 0 {
					t.Fatal("client command created owner state", paths, err)
				}
			}
		})
	}
}
