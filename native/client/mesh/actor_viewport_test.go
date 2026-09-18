//go:build meshclient

// SPDX-License-Identifier: MPL-2.0
// Producer frame setup follows Wippy system/tty acceptance fixtures.
package mesh

import (
	"context"
	"errors"
	"testing"

	"github.com/wippyai/bee/native/hive/rendezvous"
	"github.com/wippyai/runtime/api/attrs"
	ctxapi "github.com/wippyai/runtime/api/context"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/api/registry"
	"github.com/wippyai/runtime/api/relay"
	"github.com/wippyai/runtime/api/runtime"
	"github.com/wippyai/runtime/api/security"
	ttyapi "github.com/wippyai/runtime/api/tty"
	stackpkg "github.com/wippyai/runtime/cluster"
	"github.com/wippyai/runtime/cluster/internode"
	securitysys "github.com/wippyai/runtime/system/security"
	ttysys "github.com/wippyai/runtime/system/tty"
)

type producerPolicy struct{}

func (producerPolicy) ID() registry.ID { return registry.NewID("fixture", "producer") }
func (producerPolicy) Evaluate(_ security.Actor, action, _ string, _ attrs.Bag) security.Result {
	switch action {
	case "tty.mount", ttyapi.RightObserve, ttyapi.RightInput, ttyapi.RightResize:
		return security.Allow
	}
	return security.Deny
}

type producerInbox struct{ events chan ttyapi.Event }

func (p producerInbox) Send(pkg *relay.Package) error {
	for _, message := range pkg.Messages {
		for _, item := range message.Payloads {
			if event, ok := item.Data().(*ttyapi.Event); ok && event != nil {
				select {
				case p.events <- *event:
				default:
				}
			}
		}
	}
	relay.ReleasePackage(pkg)
	return nil
}

func ownerViewport(t *testing.T, stack *stackpkg.Stack) (context.Context, ttyapi.Viewport, ttyapi.Surface, <-chan ttyapi.Event) {
	t.Helper()
	service := ttysys.NewService()
	t.Cleanup(func() { service.Close() })
	transport, err := internode.NewSurfaceTransport(stack.ConnMgr, stack.Membership)
	if err != nil {
		t.Fatal(err)
	}
	if err := service.SetMesh(stack.Node.ID(), transport); err != nil {
		t.Fatal(err)
	}
	root := ttyapi.WithService(ctxapi.NewRootContext(), service)
	root = relay.WithNode(root, stack.Node)
	events := make(chan ttyapi.Event, 32)
	if err := stack.Node.RegisterHost("producer-fixture", producerInbox{events: events}); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { stack.Node.UnregisterHost("producer-fixture") })
	ctx, frame := ctxapi.OpenFrameContext(root)
	t.Cleanup(func() { frame.Close() })
	if err := frame.Set(runtime.FramePIDKey, pid.PID{Node: stack.Node.ID(), Host: "producer-fixture", UniqID: "retained"}); err != nil {
		t.Fatal(err)
	}
	if err := security.SetActor(ctx, security.Actor{ID: "fixture"}); err != nil {
		t.Fatal(err)
	}
	if err := security.SetScope(ctx, securitysys.NewScope([]security.Policy{producerPolicy{}})); err != nil {
		t.Fatal(err)
	}
	viewport, err := service.Create(ctx, 80, 24)
	if err != nil {
		t.Fatal(err)
	}
	binding, err := service.Binding(viewport.Grant())
	if err != nil {
		t.Fatal(err)
	}
	port, err := binding.Resolve(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := port.InputController().Start(); err != nil {
		t.Fatal(err)
	}
	surface, err := port.OpenSurface(ttyapi.SurfaceOptions{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { surface.Close() })
	if _, err := surface.Present(ttyapi.Frame{Rows: []string{"RETAINED_ACTOR_VIEW"}}); err != nil {
		t.Fatal(err)
	}
	return ctx, viewport, surface, events
}

func TestNativeActorLifecycleRetiresViewportWithoutStoppingOwner(t *testing.T) {
	ctx, dir, owner, _, _ := localOwner(t)
	producer, viewport, _, _ := ownerViewport(t, owner)
	for range 2 {
		var mounted ttyapi.Viewport
		var retiredFrame context.Context
		err := Local(ctx, LocalConfig{Directory: dir}, func(ctx context.Context, stack *stackpkg.Stack, descriptor rendezvous.Descriptor) error {
			return WithActor(ctx, stack, descriptor.Node, func(frame context.Context, actor *Actor) error {
				retiredFrame = frame
				ref, err := viewport.(ttyapi.MountableViewport).Mount(producer, actor.PID(), ttyapi.MountRights{Observe: true})
				if err != nil {
					return err
				}
				service := ttyapi.GetService(frame)
				if service == nil {
					return errors.New("missing native client TTY service")
				}
				mounted, err = service.Attach(frame, ref)
				if err != nil {
					return err
				}
				snapshot := mounted.Snapshot()
				if len(snapshot.Rows) == 0 || snapshot.Rows[0] != "RETAINED_ACTOR_VIEW" {
					t.Fatalf("lost retained content: %#v", snapshot.Rows)
				}
				// Deliberately leave the mount open: the real process lifecycle owns
				// retirement, even when a caller forgets explicit viewport cleanup.
				return nil
			})
		})
		if err != nil {
			t.Fatal(err)
		}
		select {
		case _, ok := <-mounted.Updates():
			if ok { // A coalesced final hint may precede closure.
				select {
				case _, ok := <-mounted.Updates():
					if ok {
						t.Fatal("mount retained multiple hints")
					}
				default:
					t.Fatal("mount still open")
				}
			}
		default:
			t.Fatal("actor exit did not retire viewport")
		}
		if err := mounted.(ttyapi.CheckedViewport).Check(retiredFrame, ttyapi.RightObserve); err == nil {
			t.Fatal("retired actor still has viewport authority")
		}
	}
}
