//go:build meshclient

// SPDX-License-Identifier: MIT
package mesh

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/wippyai/bee/native/hive/rendezvous"
	"github.com/wippyai/runtime/api/pid"
	topapi "github.com/wippyai/runtime/api/topology"
	stackpkg "github.com/wippyai/runtime/cluster"
)

func TestActorDiscoversOwnerThroughRuntimeNames(t *testing.T) {
	ctx, dir, _, _, descriptor := localOwner(t)
	expected := pid.PID{Node: descriptor.Node, Host: "bee.hive:supervisor_host", UniqID: "fixture-owner"}
	names := topapi.GetEventualRegistry(ctx)
	if names == nil {
		t.Fatal("owner missing runtime registry")
	}
	if _, err := names.Register("bee.hive.supervisor/"+descriptor.Node, expected); err != nil {
		t.Fatal(err)
	}
	var retired *Actor
	err := Local(ctx, LocalConfig{Directory: dir}, func(ctx context.Context, stack *stackpkg.Stack, owner rendezvous.Descriptor) error {
		return WithActor(ctx, stack, owner.Node, func(frame context.Context, actor *Actor) error {
			retired = actor
			canceled, cancel := context.WithCancel(frame)
			cancel()
			if _, err := actor.OwnerSupervisor(canceled); !errors.Is(err, context.Canceled) {
				t.Fatalf("lookup ignored cancellation: %v", err)
			}
			deadline, cancel := context.WithTimeout(frame, 5*time.Second)
			defer cancel()
			tick := time.NewTicker(20 * time.Millisecond)
			defer tick.Stop()
			for {
				found, err := actor.OwnerSupervisor(deadline)
				if err == nil {
					if !samePID(found, expected) {
						t.Fatalf("wrong discovered owner: %v", found)
					}
					return nil
				}
				select {
				case <-deadline.Done():
					return errors.Join(deadline.Err(), err)
				case <-tick.C:
				}
			}
		})
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := retired.OwnerSupervisor(context.Background()); err == nil {
		t.Fatal("retired client retained lookup access")
	}
}
