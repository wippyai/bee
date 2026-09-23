//go:build meshclient

// SPDX-License-Identifier: MIT
package mesh

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"

	"github.com/wippyai/bee/native/hive/rendezvous"
	"github.com/wippyai/runtime/api/payload"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/api/relay"
	stackpkg "github.com/wippyai/runtime/cluster"
	"github.com/wippyai/runtime/cluster/internode"
)

type requestCapture struct{ requests chan Message }

func (r requestCapture) Send(pkg *relay.Package) error {
	defer relay.ReleasePackage(pkg)
	for _, msg := range pkg.Messages {
		if len(msg.Payloads) != 1 {
			return errors.New("fixture: unexpected payload count")
		}
		body, ok := msg.Payloads[0].Data().([]byte)
		if !ok {
			return errors.New("fixture: unexpected payload type")
		}
		select {
		case r.requests <- Message{From: pkg.Source, Topic: msg.Topic, Body: bytes.Clone(body)}:
		default:
			return errors.New("fixture: unexpected duplicate request")
		}
	}
	return nil
}

func TestActorSendsControlAcrossNativeMesh(t *testing.T) {
	ctx, dir, owner, _, _ := localOwner(t)
	requests := make(chan Message, 1)
	if err := owner.Node.RegisterHost("admission-fixture", requestCapture{requests}); err != nil {
		t.Fatal(err)
	}
	err := joinFresh(ctx, dir, internode.ManagerTLSConfig{}, func(ctx context.Context, stack *stackpkg.Stack, descriptor rendezvous.Descriptor) error {
		return WithActor(ctx, stack, descriptor.Node, func(frame context.Context, actor *Actor) error {
			target := pid.PID{Node: descriptor.Node, Host: "admission-fixture", UniqID: "owner"}
			deadline, cancel := context.WithTimeout(frame, 3*time.Second)
			defer cancel()
			canceled, stop := context.WithCancel(frame)
			stop()
			if err := actor.Send(canceled, target, "bee.client.request", []byte(`{"request_id":"canceled"}`)); !errors.Is(err, context.Canceled) {
				t.Fatalf("canceled admission: %v", err)
			}
			body := []byte(`{"request_id":"round-trip"}`)
			if err := actor.Send(deadline, target, "bee.client.request", body); err != nil {
				return err
			}
			var request Message
			select {
			case request = <-requests:
			case <-deadline.Done():
				return deadline.Err()
			}
			if !samePID(request.From, actor.PID()) || request.Topic != "bee.client.request" || !bytes.Equal(request.Body, body) {
				t.Fatalf("changed request: %#v", request)
			}
			reply := relay.NewPackage(target, request.From, "bee.client.reply", payload.NewPayload(request.Body, payload.JSON))
			if err := owner.Router.SendContext(deadline, reply); err != nil {
				relay.ReleasePackage(reply)
				return err
			}
			received, err := actor.Receive(deadline)
			if err != nil {
				return err
			}
			if !samePID(received.From, target) || !bytes.Equal(received.Body, body) {
				t.Fatal("changed reply")
			}
			select {
			case extra := <-requests:
				t.Fatalf("unexpected extra request: %#v", extra)
			default:
			}
			return nil
		})
	})
	if err != nil {
		t.Fatal(err)
	}
}
