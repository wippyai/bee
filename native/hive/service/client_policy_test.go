// SPDX-License-Identifier: MIT
package service

import (
	"context"
	"testing"

	"github.com/wippyai/runtime/api/attrs"
	ctxapi "github.com/wippyai/runtime/api/context"
	"github.com/wippyai/runtime/api/registry"
	"github.com/wippyai/runtime/api/security"
	securitysys "github.com/wippyai/runtime/system/security"
)

type testClientPolicy struct{}

func (testClientPolicy) ID() registry.ID { return registry.ParseID("bee.hive:test_client") }
func (testClientPolicy) Evaluate(_ security.Actor, action, resource string, _ attrs.Bag) security.Result {
	if action == "bee.desktop.local_client" && resource == "client" {
		return security.Allow
	}
	return security.Undefined
}

func TestClientPolicyIsConfinedToSupervisorChildFrame(t *testing.T) {
	parent, frame := ctxapi.OpenFrameContext(ctxapi.NewRootContext())
	if err := security.SetActor(parent, security.Actor{ID: ActorID}); err != nil {
		t.Fatal(err)
	}
	if err := security.SetScope(parent, securitysys.NewScope(nil)); err != nil {
		t.Fatal(err)
	}
	frame.Seal()
	policy := testClientPolicy{}
	child, err := clientPolicyContext(parent, policy)
	if err != nil {
		t.Fatal(err)
	}
	childScope, ok := security.GetScope(child)
	if !ok || !childScope.Contains(policy.ID()) {
		t.Fatal("child missing host policy")
	}
	parentScope, _ := security.GetScope(parent)
	if parentScope.Contains(policy.ID()) {
		t.Fatal("parent scope widened")
	}
	sibling, _ := ctxapi.ForkFrameContext(parent)
	siblingScope, _ := security.GetScope(sibling)
	if siblingScope.Contains(policy.ID()) {
		t.Fatal("sibling scope widened")
	}
	if security.SetScope(child, securitysys.NewScope(nil)) == nil {
		t.Fatal("child frame left mutable")
	}
	if _, err := clientPolicyContext(context.Background(), policy); err == nil {
		t.Fatal("missing actor accepted")
	}
}

func TestDynamicClientGrantRemainsHostSelected(t *testing.T) {
	cfg := desktopConfig()
	cfg.Desktop.AllowedNodes = nil
	if cfg.Validate() == nil {
		t.Fatal("empty admission accepted without policy")
	}
	cfg.Desktop.ClientPolicy = testClientPolicy{}
	if err := cfg.Validate(); err != nil {
		t.Fatal(err)
	}
	input := cfg.Desktop.input()
	if input["local_clients"] != true {
		t.Fatal("host policy mode missing")
	}
	if nodes, ok := input["allowed_nodes"].([]string); !ok || nodes == nil || len(nodes) != 0 {
		t.Fatal("empty list must remain a Lua table")
	}
	if _, exists := input["ClientPolicy"]; exists {
		t.Fatal("native policy exported")
	}
}
