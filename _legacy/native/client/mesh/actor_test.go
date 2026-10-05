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
	"github.com/wippyai/runtime/cluster/internode"
)

func TestNativeActorReceivesOwnerReplyAndRetiresFrame(t *testing.T) {
	ctx, dir, owner, _, _ := localOwner(t)
	var retained context.Context
	var previous pid.PID
	for range 2 {
		err := joinFresh(ctx, dir, internode.ManagerTLSConfig{}, func(ctx context.Context, stack *stackpkg.Stack, descriptor rendezvous.Descriptor) error {
			err := WithActor(ctx, stack, descriptor.Node, func(frame context.Context, actor *Actor) error {
				retained = frame
				actual, ok := runtime.GetFramePID(frame)
				if !ok || !actual.Equal(actor.PID()) || actual.Node != stack.Node.ID() || actual.Host != ActorHost || actual.UniqID == "" {
					t.Fatalf("invalid runtime recipient: %v", actual)
				}
				if actual.Equal(previous) {
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
				// The actual transport peer is the owner node. Keep a different
				// logical sender to verify admission uses runtime ingress provenance.
				source := pid.PID{Node: "claimed-node", Host: "fixture", UniqID: "supervisor"}
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
				if !message.From.Equal(source) || message.Topic != "bee.client.reply" || string(message.Body) != string(body) {
					t.Fatalf("changed peer envelope: %#v", message)
				}
				return nil
			})
			if _, ok := stack.Node.GetHost(ActorHost); ok {
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
	ctx, dir, owner, _, _ := localOwner(t)
	err := joinFresh(ctx, dir, internode.ManagerTLSConfig{}, func(ctx context.Context, stack *stackpkg.Stack, descriptor rendezvous.Descriptor) error {
		return WithActor(ctx, stack, descriptor.Node, func(frame context.Context, actor *Actor) error {
			source := pid.PID{Node: descriptor.Node, Host: "fixture", UniqID: "supervisor"}
			pkg := relay.AcquirePackage()
			pkg.Source = source
			pkg.Target = actor.PID()
			pkg.IngressNode = pid.NodeID(descriptor.Node)
			for range maxMessages + 1 {
				msg := relay.AcquireMessage()
				msg.Topic = "bee.client.reply"
				msg.Payloads = payload.Payloads{payload.NewPayload([]byte(`{"id":1}`), payload.JSON)}
				pkg.Messages = append(pkg.Messages, msg)
			}
			if err := owner.Router.Send(pkg); err != nil {
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
		name    string
		source  string
		ingress string
	}{
		{name: "empty-ingress", source: "owner", ingress: ""},
		{name: "foreign-ingress", source: "owner", ingress: "intruder"},
	} {
		t.Run(test.name, func(t *testing.T) {
			actor := &Actor{owner: "owner", inbox: make(chan Message, 1)}
			proc := &nativeActor{actor: actor}
			pkg := relay.NewPackage(pid.PID{Node: test.source, Host: "supervisor", UniqID: "one"}, pid.PID{}, "reply", payload.NewPayload([]byte(`{"id":"claim"}`), payload.JSON))
			pkg.IngressNode = pid.NodeID(test.ingress)
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

func TestActorAuthenticatesIngressAndPreservesLogicalSender(t *testing.T) {
	actor := &Actor{owner: "owner", inbox: make(chan Message, 1)}
	proc := &nativeActor{actor: actor}
	source := pid.PID{Node: "claimed-node", Host: "supervisor", UniqID: "one"}
	pkg := relay.NewPackage(source, pid.PID{}, "reply", payload.NewPayload([]byte(`{"id":"reply"}`), payload.JSON))
	pkg.IngressNode = pid.NodeID("owner")
	var output process.StepOutput
	if err := proc.Step([]process.Event{{Type: process.EventMessage, Data: pkg}}, &output); err != nil {
		t.Fatal(err)
	}
	select {
	case message := <-actor.inbox:
		if !message.From.Equal(source) || string(message.Body) != `{"id":"reply"}` {
			t.Fatalf("logical sender or body changed: %+v", message)
		}
	default:
		t.Fatal("authenticated owner ingress did not reach the client inbox")
	}
}
