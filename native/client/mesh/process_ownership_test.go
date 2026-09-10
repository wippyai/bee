//go:build meshclient

// SPDX-License-Identifier: MIT
package mesh

import (
	"errors"
	"testing"

	"github.com/wippyai/runtime/api/payload"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/api/process"
	"github.com/wippyai/runtime/api/relay"
)

type countedLease struct{ released int }

func (l *countedLease) Release() { l.released++ }

func TestActorReleasesEveryConsumedPackage(t *testing.T) {
	for _, mode := range []string{"accepted", "rejected", "overflow"} {
		t.Run(mode, func(t *testing.T) {
			actor := &Actor{owner: "owner", inbox: make(chan Message, 1)}
			proc := &nativeActor{actor: actor}
			if mode == "overflow" {
				actor.inbox <- Message{}
			}
			leases := make([]*countedLease, 3)
			events := make([]process.Event, 3)
			for i := range events {
				lease := &countedLease{}
				leases[i] = lease
				source := "owner"
				if mode == "rejected" || (mode == "accepted" && i > 0) {
					source = "other"
				}
				pkg := relay.NewPackage(pid.PID{Node: source, Host: "fixture", UniqID: "owner"}, pid.PID{}, "reply", payload.NewPayload([]byte(`{"ok":true}`), payload.JSON))
				pkg.Messages[0].SetRetentionLease(lease)
				events[i] = process.Event{Type: process.EventMessage, Data: pkg}
			}
			var out process.StepOutput
			err := proc.Step(events, &out)
			if mode == "overflow" {
				if !errors.Is(err, ErrInboxFull) {
					t.Fatal(err)
				}
			} else if err != nil {
				t.Fatal(err)
			}
			for i, lease := range leases {
				if lease.released != 1 {
					t.Fatalf("package %d released %d times", i, lease.released)
				}
			}
			if mode == "accepted" && string((<-actor.inbox).Body) != `{"ok":true}` {
				t.Fatal("copied body lost during package release")
			}
		})
	}
}
