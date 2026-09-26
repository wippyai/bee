// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"path/filepath"
	"strings"
	"testing"

	app "github.com/wippyai/runtime/cmd/app"
)

func TestParseUpgradeCommand(t *testing.T) {
	for _, test := range []struct {
		name string
		args []string
		want upgradeCommand
	}{
		{name: "candidate", args: []string{"/tmp/bee", "--digest", strings.Repeat("a", 64)}, want: upgradeCommand{candidate: "/tmp/bee", digest: strings.Repeat("a", 64)}},
		{name: "rollback", args: []string{"--rollback"}, want: upgradeCommand{rollback: true}},
	} {
		t.Run(test.name, func(t *testing.T) {
			got, err := parseUpgradeCommand(test.args)
			if err != nil {
				t.Fatal(err)
			}
			if got != test.want {
				t.Fatalf("parsed command = %+v, want %+v", got, test.want)
			}
		})
	}

	for _, args := range [][]string{
		{},
		{"/tmp/bee"},
		{"/tmp/bee", "--digest"},
		{"/tmp/bee", "--digest", ""},
		{"/tmp/bee", "hash", strings.Repeat("a", 64)},
		{"--rollback", "extra"},
	} {
		if _, err := parseUpgradeCommand(args); err == nil || err.Error() != "bee upgrade requires PATH --digest SHA256 or --rollback" {
			t.Errorf("parse %q error = %v", args, err)
		}
	}
}

func TestPlanMapsUpgradeToProjectState(t *testing.T) {
	root := filepath.Join(t.TempDir(), "state")
	project := makeProject(t)
	host := newHost(systemHostResolver())
	plan, err := host.Plan(context.Background(), app.Launch{
		Op: app.OpRun, Command: desktopCommand, State: root, Dir: project,
		Args: []string{"upgrade", "/tmp/bee", "--digest", strings.Repeat("a", 64)},
	})
	if err != nil {
		t.Fatal(err)
	}
	want, err := DefaultProjectStateDir(root, project)
	if err != nil {
		t.Fatal(err)
	}
	if plan.DefaultState != want || plan.Run == nil || plan.Prepare != nil || host.ownerState != "" {
		t.Fatalf("upgrade plan = %#v, owner state %q; want state %q and direct command run", plan, host.ownerState, want)
	}
}

func TestPlanRejectsMalformedUpgradeBeforeProjectSelection(t *testing.T) {
	for _, args := range [][]string{
		{"upgrade"},
		{"upgrade", "--rollback", "extra"},
		{"upgrade", "/tmp/bee", "--digest"},
	} {
		state, missing, untouched := untouchedLaunch(t)
		host := newHost(systemHostResolver())
		_, err := host.Plan(context.Background(), app.Launch{
			Op: app.OpRun, Command: desktopCommand, State: state, Dir: missing, Args: args,
		})
		if err == nil || err.Error() != "bee upgrade requires PATH --digest SHA256 or --rollback" {
			t.Fatalf("plan for %q error = %v", args, err)
		}
		untouched()
	}
}
