//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package desktop

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	launchpkg "github.com/wippyai/bee/native/launch"
	app "github.com/wippyai/runtime/cmd/app"
)

// privateDir mirrors t.TempDir with owner-only permissions, which the protected
// project-state receipt requires.
func privateDir(t *testing.T) string {
	t.Helper()
	directory := filepath.Join(t.TempDir(), "private")
	if err := os.Mkdir(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	return directory
}

func testHost(t *testing.T) *Host {
	t.Helper()
	host, err := New(Options{Node: "host-plan-test", Lifetime: time.Minute})
	if err != nil {
		t.Fatal(err)
	}
	return host
}

// A non-explicit launch must carry the project's selected state in the plan, so
// the runtime actually runs the project directory's own state. The model applies
// only Plan.State, so selecting state on the forwarded launch is not enough.
func TestPlanCarriesSelectedProjectState(t *testing.T) {
	host := testHost(t)
	project := privateDir(t)
	root := privateDir(t)
	plan, err := host.Plan(context.Background(), app.Launch{
		Op: app.OpRun, Command: "bee", Dir: project, State: root,
	})
	if err != nil {
		t.Fatal(err)
	}
	want, err := launchpkg.DefaultProjectStateDir(root, project)
	if err != nil {
		t.Fatal(err)
	}
	if plan.State != want {
		t.Fatalf("plan state = %q, want the project state %q", plan.State, want)
	}
	if plan.State == root {
		t.Fatal("plan kept the shared root instead of the project state")
	}
}

// An explicit --state launch must keep exactly the state the user selected.
func TestPlanKeepsExplicitState(t *testing.T) {
	host := testHost(t)
	selected := filepath.Join(privateDir(t), "chosen")
	plan, err := host.Plan(context.Background(), app.Launch{
		Op: app.OpRun, Command: "bee", Dir: privateDir(t), State: selected, Explicit: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if plan.State != "" && plan.State != selected {
		t.Fatalf("explicit state replaced by %q", plan.State)
	}
}

// Reserved verbs keep the runtime's own route while targeting the same project
// state as an ordinary launch from that directory.
func TestPlanSelectsProjectStateForReservedVerbs(t *testing.T) {
	host := testHost(t)
	project := privateDir(t)
	root := privateDir(t)
	want, err := launchpkg.DefaultProjectStateDir(root, project)
	if err != nil {
		t.Fatal(err)
	}
	for _, op := range []app.Op{app.OpUpdate, app.OpRecover, app.OpWippy} {
		plan, err := host.Plan(context.Background(), app.Launch{
			Op: op, Command: "bee", Dir: project, State: root,
		})
		if err != nil {
			t.Fatal(err)
		}
		if plan.Run != nil || plan.Prepare != nil || plan.State != want || plan.Command != "" {
			t.Fatalf("reserved verb %v received the wrong state-only plan: %+v", op, plan)
		}
	}
}
