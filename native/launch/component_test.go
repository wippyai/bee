//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package launch

import (
	"context"
	"github.com/wippyai/runtime/api/boot"
	app "github.com/wippyai/runtime/cmd/app"
	"testing"
)

func TestStartRouteDefersPreparationToRuntimeLock(t *testing.T) {
	calls := 0
	launcher, err := NewOwnerLauncher("bee", "retained-owner", func(context.Context, app.Launch) (boot.Config, func() error, error) {
		calls++
		return nil, nil, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	launch := app.Launch{Op: app.OpRun, Command: "bee", Args: []string{"start"}}
	plan, err := launcher.Plan(context.Background(), launch)
	if err != nil || plan.Command != "retained-owner" || plan.Args == nil || len(plan.Args) != 0 || plan.Prepare == nil || plan.Run != nil || calls != 0 {
		t.Fatalf("invalid start plan: %+v %v calls=%d", plan, err, calls)
	}
	if _, release, err := plan.Prepare(context.Background()); err != nil || calls != 1 {
		t.Fatal(err, calls)
	} else if release != nil {
		t.Fatal("start route returned an unexpected release")
	}
	for _, operation := range []app.Op{app.OpUpdate, app.OpRecover, app.OpWippy} {
		other := launch
		other.Op = operation
		plan, err := launcher.Plan(context.Background(), other)
		if err != nil || plan.Prepare != nil || plan.Run != nil || plan.Command != "" {
			t.Fatal("reserved operation intercepted", plan, err)
		}
	}
	launch.Args = []string{"start", "extra"}
	if _, err := launcher.Plan(context.Background(), launch); err == nil {
		t.Fatal("extra argument ignored")
	}
	launch.Args = nil
	plan, err = launcher.Plan(context.Background(), launch)
	if err != nil || plan.Prepare != nil || plan.Command != "" {
		t.Fatal("ordinary launch changed", plan, err)
	}
	if calls != 1 {
		t.Fatal("preparation happened before lock", calls)
	}
}
