//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package launch

import (
	"context"
	application "github.com/wippyai/runtime/api/application"
	"testing"
)

func TestStartRouteDefersPreparationToRuntimeLock(t *testing.T) {
	calls := 0
	launcher, err := NewOwnerLauncher("bee", "retained-owner", func(context.Context, application.LaunchRequest) (application.OwnerPlan, error) {
		calls++
		return application.OwnerPlan{}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	request := application.LaunchRequest{Operation: application.RunApplication, Command: "bee", Arguments: []string{"start"}}
	plan, err := launcher.PrepareLaunch(context.Background(), request)
	if err != nil || plan.Command != "retained-owner" || plan.Arguments == nil || len(plan.Arguments) != 0 || plan.PrepareOwner == nil || plan.Attach != nil || plan.Handled || calls != 0 {
		t.Fatalf("invalid start plan: %+v %v calls=%d", plan, err, calls)
	}
	if _, err := plan.PrepareOwner(context.Background(), request); err != nil || calls != 1 {
		t.Fatal(err, calls)
	}
	for _, operation := range []application.Operation{application.RunRuntime, application.Update} {
		other := request
		other.Operation = operation
		plan, err := launcher.PrepareLaunch(context.Background(), other)
		if err != nil || plan.PrepareOwner != nil || plan.Command != "" {
			t.Fatal("reserved operation intercepted", plan, err)
		}
	}
	request.Base = true
	if _, err := launcher.PrepareLaunch(context.Background(), request); err == nil {
		t.Fatal("base start accepted")
	}
	request.Base = false
	request.Arguments = []string{"start", "extra"}
	if _, err := launcher.PrepareLaunch(context.Background(), request); err == nil {
		t.Fatal("extra argument ignored")
	}
	request.Arguments = nil
	plan, err = launcher.PrepareLaunch(context.Background(), request)
	if err != nil || plan.PrepareOwner != nil || plan.Command != "" {
		t.Fatal("ordinary launch changed", plan, err)
	}
	if calls != 1 {
		t.Fatal("preparation happened before lock", calls)
	}
}
