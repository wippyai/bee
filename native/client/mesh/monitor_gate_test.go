//go:build meshclient && meshmonitorproof

// SPDX-License-Identifier: MIT
package mesh

import (
	"context"
	"testing"
	"time"

	"github.com/wippyai/bee/native/hive/rendezvous"
	"github.com/wippyai/runtime/api/payload"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/api/relay"
	topapi "github.com/wippyai/runtime/api/topology"
	stackpkg "github.com/wippyai/runtime/cluster"
	"github.com/wippyai/runtime/cluster/internode"
	topologysys "github.com/wippyai/runtime/system/topology"
)

type monitorProbe struct{ events chan string }

func (p monitorProbe) Send(pkg *relay.Package) error {
	for _, message := range pkg.Messages {
		select {
		case p.events <- message.Topic:
		default:
		}
	}
	relay.ReleasePackage(pkg)
	return nil
}

// This is an explicit failing runtime integration gate until native remote
// monitor ingress exists. It is not part of mesh-client-check's passing slice.
func TestNativeRemoteMonitorMustObserveClientActorExit(t *testing.T) {
	ctx, dir, owner, _, _ := localOwner(t)
	watcher := pid.PID{Node: owner.Node.ID(), Host: "monitor-probe", UniqID: "watcher"}
	notifications := make(chan string, 8)
	if err := owner.Node.RegisterHost(watcher.Host, monitorProbe{notifications}); err != nil {
		t.Fatal(err)
	}
	defer owner.Node.UnregisterHost(watcher.Host)
	topology := topologysys.NewTopology(owner.Router, owner.Node.ID())
	if err := topology.Register(watcher); err != nil {
		t.Fatal(err)
	}
	err := joinFresh(ctx, dir, internode.ManagerTLSConfig{}, func(ctx context.Context, stack *stackpkg.Stack, descriptor rendezvous.Descriptor) error {
		err := WithActor(ctx, stack, descriptor.Node, func(frame context.Context, actor *Actor) error {
			if err := topology.Monitor(watcher, actor.PID()); err != nil {
				return err
			}
			// Monitor and barrier share the runtime's application FIFO class. Seeing
			// the barrier rules out simply closing the actor before monitor delivery.
			barrier := relay.NewPackage(watcher, actor.PID(), "bee.mesh.barrier", payload.NewPayload([]byte(`{"barrier":1}`), payload.JSON))
			if err := owner.Router.Send(barrier); err != nil {
				return err
			}
			received, err := actor.Receive(frame)
			if err != nil {
				return err
			}
			if received.Topic != "bee.mesh.barrier" {
				t.Fatal("unexpected barrier")
			}
			return nil
		})
		if err != nil {
			return err
		}
		// Keep the native client transport alive after its actual host has drained.
		select {
		case topic := <-notifications:
			if topic != topapi.TopicEvents {
				t.Fatalf("unexpected notification %q", topic)
			}
		case <-time.After(time.Second):
			t.Fatal("native runtime accepted remote monitor but emitted no EXIT after client actor completion")
		case <-ctx.Done():
			return ctx.Err()
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}
