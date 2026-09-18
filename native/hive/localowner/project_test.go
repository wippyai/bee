//go:build meshclient

// SPDX-License-Identifier: MIT
package localowner

import (
	"context"
	"testing"
	"time"

	launch "github.com/wippyai/runtime/api/application"
)

func TestProjectNodesHaveStableDistinctNames(t *testing.T) {
	first, second := t.TempDir(), t.TempDir()
	prepare := func(state string) string {
		t.Helper()
		owner, err := New(Options{Node: "Antares", Lifetime: time.Hour})
		if err != nil {
			t.Fatal(err)
		}
		plan, err := owner.PrepareProjectOwner(context.Background(), launch.LaunchRequest{Operation: launch.RunApplication, StateDir: state, Directory: state})
		if err != nil {
			t.Fatal(err)
		}
		defer plan.Close()
		name, ok := plan.Config.Get("cluster.name")
		if !ok {
			t.Fatal("missing native node name")
		}
		relay, ok := plan.Config.Get("relay.node_name")
		if !ok || relay != name {
			t.Fatal("relay and mesh identities disagree", relay, name)
		}
		value, ok := name.(string)
		if !ok || value == "Antares" || len(value) > 128 {
			t.Fatal(name)
		}
		return value
	}
	a, b := prepare(first), prepare(second)
	if a == b {
		t.Fatal("project nodes collide")
	}
	if a != prepare(first) {
		t.Fatal("project restart changed node identity")
	}
}
