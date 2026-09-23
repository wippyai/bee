//go:build meshclient

// SPDX-License-Identifier: MIT
package mesh

import (
	"context"
	"testing"

	"github.com/wippyai/runtime/api/pid"
)

// TestOwnerSupervisorUsesPinnedAddress proves a client that was given the
// owner's supervisor address by the rendezvous descriptor resolves it without
// the cluster-wide name, which a raft-disabled owner never publishes.
func TestOwnerSupervisorUsesPinnedAddress(t *testing.T) {
	pinned := pid.PID{Node: "owner-node", Host: "bee.hive:supervisor_host", UniqID: "0x1"}
	actor := &Actor{owner: "owner-node"}
	actor.PinSupervisor(pinned)
	got, err := actor.OwnerSupervisor(context.Background())
	if err != nil {
		t.Fatalf("OwnerSupervisor: %v", err)
	}
	if got != pinned {
		t.Fatalf("supervisor = %v, want %v", got, pinned)
	}
	// A pinned address for another node is refused before any lookup runs.
	if _, ok := (&Actor{owner: "owner-node", pinned: pid.PID{Node: "other", Host: "bee.hive:supervisor_host", UniqID: "0x2"}}).pinnedSupervisor(); ok {
		t.Fatal("pinned address for another node was accepted")
	}
	// An address on the wrong host is refused.
	if _, ok := (&Actor{owner: "owner-node", pinned: pid.PID{Node: "owner-node", Host: "bee:workers", UniqID: "0x3"}}).pinnedSupervisor(); ok {
		t.Fatal("pinned address on another host was accepted")
	}
	// A pinned address without an identity is refused.
	if _, ok := (&Actor{owner: "owner-node", pinned: pid.PID{Node: "owner-node", Host: "bee.hive:supervisor_host"}}).pinnedSupervisor(); ok {
		t.Fatal("pinned address without an identity was accepted")
	}
}
