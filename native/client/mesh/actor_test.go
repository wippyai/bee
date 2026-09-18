//go:build meshclient

// SPDX-License-Identifier: MIT
package mesh

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/wippyai/bee/native/hive/rendezvous"
	ctxapi "github.com/wippyai/runtime/api/context"
	"github.com/wippyai/runtime/api/payload"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/api/process"
	"github.com/wippyai/runtime/api/registry"
	"github.com/wippyai/runtime/api/relay"
	"github.com/wippyai/runtime/api/runtime"
	"github.com/wippyai/runtime/api/security"
	topapi "github.com/wippyai/runtime/api/topology"
	stackpkg "github.com/wippyai/runtime/cluster"
)

func TestNativeActorReceivesOwnerReplyAndRetiresFrame(t *testing.T) {
	ctx, dir, owner, _, _ := localOwner(t)
	var retained context.Context
	var previous pid.PID
	for range 2 {
		err := Local(ctx, LocalConfig{Directory: dir}, func(ctx context.Context, stack *stackpkg.Stack, descriptor rendezvous.Descriptor) error {
			err := WithActor(ctx, stack, descriptor.Node, func(frame context.Context, actor *Actor) error {
				retained = frame
				actual, ok := runtime.GetFramePID(frame)
				if !ok || !samePID(actual, actor.PID()) || actual.Node != stack.Node.ID() || actual.Host != actorHost || actual.UniqID == "" {
					t.Fatalf("invalid runtime recipient: %v", actual)
				}
				if samePID(actual, previous) {
					t.Fatal("reused client identity")
				}
				previous = actual
				if err := topapi.GetTopology(frame).Register(actual); !errors.Is(err, topapi.ErrPIDAlreadyRegistered) {
					t.Fatalf("not registered in topology: %v", err)
				}
				if registry.GetRegistry(frame) != nil {
					t.Fatal("client loaded a registry")
				}
				if _, ok := security.GetScope(frame); !ok {
					t.Fatal("missing explicit client scope")
				}
				if !ctxapi.FrameFromContext(frame).IsSealed() {
					t.Fatal("mutable recipient frame")
				}
				source := pid.PID{Node: descriptor.Node, Host: "fixture", UniqID: "supervisor"}
				body := []byte(`{"request_id":"proof","from":"payload-is-not-identity"}`)
				// The owner fixture sends through actual internode routing; it is not a
				// production supervisor or an admission decision.
				pkg := relay.NewPackage(source, actual, "bee.client.reply", payload.NewPayload(body, payload.JSON))
				if err := owner.Router.Send(pkg); err != nil {
					return err
				}
				deadline, cancel := context.WithTimeout(frame, 3*time.Second)
				defer cancel()
				message, err := actor.Receive(deadline)
				if err != nil {
					return err
				}
				if !samePID(message.From, source) || message.Topic != "bee.client.reply" || string(message.Body) != string(body) {
					t.Fatalf("changed peer envelope: %#v", message)
				}
				return nil
			})
			if _, ok := stack.Node.GetHost(actorHost); ok {
				t.Fatal("native client host leaked")
			}
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, ok := runtime.GetFramePID(retained); ok {
			t.Fatal("retired frame still has process authority")
		}
		if retained.Err() == nil {
			t.Fatal("retired actor context is live")
		}
	}
}

func TestActorInboxOverflowCancelsConsumer(t *testing.T) {
	ctx, dir, _, _, _ := localOwner(t)
	err := Local(ctx, LocalConfig{Directory: dir}, func(ctx context.Context, stack *stackpkg.Stack, descriptor rendezvous.Descriptor) error {
		return WithActor(ctx, stack, descriptor.Node, func(frame context.Context, actor *Actor) error {
			source := pid.PID{Node: descriptor.Node, Host: "fixture", UniqID: "supervisor"}
			pkg := relay.AcquirePackage()
			pkg.Source = source
			// Trusted local injection exercises queue overflow after owner-node admission.
			pkg.Target = actor.PID()
			for range maxMessages + 1 {
				msg := relay.AcquireMessage()
				msg.Topic = "bee.client.reply"
				msg.Payloads = payload.Payloads{payload.NewPayload([]byte(`{"id":1}`), payload.JSON)}
				pkg.Messages = append(pkg.Messages, msg)
			}
			if err := stack.Node.Send(pkg); err != nil {
				relay.ReleasePackage(pkg)
				return err
			}
			select {
			case <-frame.Done():
			case <-time.After(time.Second):
				t.Fatal("inbox overflow did not cancel physical client")
			}
			_, err := actor.Receive(context.Background())
			if !errors.Is(err, ErrInboxFull) {
				t.Fatalf("lost overflow cause: %v", err)
			}
			return err
		})
	})
	if !errors.Is(err, ErrInboxFull) {
		t.Fatalf("lost actor failure on return: %v", err)
	}
}

func TestActorRejectsForeignOwnerNodes(t *testing.T) {
	for _, test := range []struct {
		name   string
		source string
	}{
		{name: "empty", source: ""},
		{name: "different-peer", source: "other"},
	} {
		t.Run(test.name, func(t *testing.T) {
			actor := &Actor{owner: "owner", inbox: make(chan Message, 1)}
			proc := &nativeActor{actor: actor}
			pkg := relay.NewPackage(pid.PID{Node: test.source, Host: "supervisor", UniqID: "one"}, pid.PID{}, "reply", payload.NewPayload([]byte(`{"id":"claim"}`), payload.JSON))
			var output process.StepOutput
			if err := proc.Step([]process.Event{{Type: process.EventMessage, Data: pkg}}, &output); err != nil {
				t.Fatal(err)
			}
			if len(actor.inbox) != 0 {
				t.Fatal("unverified owner claim entered inbox")
			}
		})
	}
}
