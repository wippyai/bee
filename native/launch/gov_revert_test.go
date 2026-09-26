// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"path/filepath"
	"reflect"
	"testing"

	app "github.com/wippyai/runtime/cmd/app"
)

func TestGovernanceRevertUsesHeadlessRecoveryCommand(t *testing.T) {
	owner := "bee.super_edit:0123456789abcdef0123456789abcdef.vendor.alpha.00000000-0000-7000-8000-000000000000"
	state := filepath.Join(t.TempDir(), "state")
	host := newHost(systemHostResolver())
	plan, err := host.Plan(context.Background(), app.Launch{Command: "bee", State: state, Dir: t.TempDir(),
		Args: []string{"gov", "revert", owner}})
	if err != nil {
		t.Fatal(err)
	}
	if plan.Command != governanceRecoveryCommand || !reflect.DeepEqual(plan.Args, []string{"revert", owner}) ||
		plan.Run != nil || plan.Prepare != nil {
		t.Fatalf("governance recovery plan = %#v", plan)
	}
}

func TestGovernanceRevertRejectsMalformedCommandsBeforeSelectingState(t *testing.T) {
	for _, args := range [][]string{{"gov"}, {"gov", "enable", "vendor.alpha"}, {"gov", "revert"},
		{"gov", "revert", "bad owner"}, {"gov", "revert", "vendor.alpha"}, {"gov", "revert", "bee:bad..owner"}} {
		host := newHost(systemHostResolver())
		_, err := host.Plan(context.Background(), app.Launch{Command: "bee", State: t.TempDir(), Dir: t.TempDir(), Args: args})
		if err == nil {
			t.Fatalf("malformed governance command %q was accepted", args)
		}
	}
}
