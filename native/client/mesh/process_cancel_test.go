//go:build meshclient

// SPDX-License-Identifier: MIT
package mesh

import (
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/api/process"
	"github.com/wippyai/runtime/api/topology"
	"testing"
)

func TestNativeActorHonorsOnlyItsRuntimeCancellation(t *testing.T) {
	for _, mode := range []string{"scheduler", "remote", "other-target"} {
		t.Run(mode, func(t *testing.T) {
			id := pid.PID{Node: "client", Host: "native", UniqID: "actor"}
			actor := &Actor{id: id, owner: "owner", inbox: make(chan Message, 1)}
			proc := &nativeActor{actor: actor}
			pkg := topology.CancelPackage(pid.PID{}, id, "shutdown")
			if mode == "remote" {
				pkg.Source.Node = "owner"
			}
			if mode == "other-target" {
				pkg.Target.UniqID = "other"
			}
			lease := &countedLease{}
			pkg.Messages[0].SetRetentionLease(lease)
			var out process.StepOutput
			if err := proc.Step([]process.Event{{Type: process.EventMessage, Data: pkg}}, &out); err != nil {
				t.Fatal(err)
			}
			if out.IsDone() != (mode == "scheduler") {
				t.Fatalf("unexpected completion: %v", out.IsDone())
			}
			if lease.released != 1 {
				t.Fatalf("cancellation package released %d times", lease.released)
			}
			if len(actor.inbox) != 0 {
				t.Fatal("lifecycle event entered application inbox")
			}
		})
	}
}
