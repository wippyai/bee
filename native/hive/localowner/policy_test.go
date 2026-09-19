//go:build meshclient

// SPDX-License-Identifier: MIT

package localowner

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"testing"
	"time"

	"github.com/wippyai/bee/native/hive/rendezvous"
	"github.com/wippyai/runtime/api/security"
	app "github.com/wippyai/runtime/cmd/app"
)

func TestLocalClientPolicyFencesEnrollmentAndExecution(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	stateDir := t.TempDir()
	// The owner's preparation runs under the real application state lock, so the
	// test takes that same lock through the model's own runner.
	unlock, err := holdState(t, stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := unlock(); err != nil {
			t.Error(err)
		}
	}()
	owner, err := New(Options{Node: "owner", Lifetime: time.Hour})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := owner.ClientPolicy(); err == nil {
		t.Fatal("unprepared owner issued policy")
	}
	_, release, err := owner.PrepareOwner(ctx, app.Launch{Op: app.OpRun, State: stateDir})
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	policy, err := owner.ClientPolicy()
	if err != nil {
		t.Fatal(err)
	}
	actor := security.Actor{ID: "bee.hive.supervisor"}
	sender := "{client@bee.client:native|actor}"
	check := func(want security.Result) {
		t.Helper()
		if got := policy.Evaluate(actor, ClientAction, sender, nil); got != want {
			t.Fatalf("decision=%v want=%v", got, want)
		}
	}
	check(security.Deny)
	enrollment, err := rendezvous.NewEnrollment(owner.state.directory)
	if err != nil {
		t.Fatal(err)
	}
	public, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	lease, _, err := enrollment.RegisterHeld(ctx, owner.state.execution, "client", public)
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Close(context.Background())
	check(security.Allow)
	for _, resource := range []string{"invalid", "{client@ordinary|actor}", "{unknown@bee.client:native|actor}", "{owner@bee.client:native|actor}"} {
		if policy.Evaluate(actor, ClientAction, resource, nil) != security.Deny {
			t.Fatalf("allowed %q", resource)
		}
	}
	if policy.Evaluate(security.Actor{ID: "ordinary-app"}, ClientAction, sender, nil) != security.Deny {
		t.Fatal("foreign actor allowed")
	}
	if policy.Evaluate(actor, "process.spawn", sender, nil) != security.Undefined {
		t.Fatal("policy affected unrelated authority")
	}
	if err := lease.Close(ctx); err != nil {
		t.Fatal(err)
	}
	check(security.Deny)
	lease, _, err = enrollment.RegisterHeld(ctx, owner.state.execution, "client", public)
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Close(context.Background())
	check(security.Allow)
	if err := enrollment.Initialize(ctx, "1123456789abcdef0123456789abcdef", make([]byte, 32)); err != nil {
		t.Fatal(err)
	}
	check(security.Deny)
	cancel()
	check(security.Deny)
	if _, err := owner.ClientPolicy(); err == nil {
		t.Fatal("retired owner issued policy")
	}
}
