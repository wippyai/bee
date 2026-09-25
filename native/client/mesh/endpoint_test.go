//go:build meshclient

// SPDX-License-Identifier: MIT
package mesh

import (
	"context"
	"errors"
	"testing"
	"time"

	ctxapi "github.com/wippyai/runtime/api/context"
	"github.com/wippyai/runtime/api/payload"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/api/relay"
	topapi "github.com/wippyai/runtime/api/topology"
	relaysys "github.com/wippyai/runtime/system/relay"
	topologysys "github.com/wippyai/runtime/system/topology"
)

// cancellableCapture is the supervisor fixture: node routing requires
// cancellable delivery from every local receiver.
type cancellableCapture struct{ requestCapture }

func (c cancellableCapture) SendContext(_ context.Context, pkg *relay.Package) error {
	return c.Send(pkg)
}

// luaTranscoder stands in for the node transcoder: a local Lua process sends
// its reply in the Lua format, which the node converts to Go values.
type luaTranscoder struct{}

func (luaTranscoder) Unmarshal(payload.Payload, any) error { return errors.New("unused") }
func (luaTranscoder) Transcode(value payload.Payload, format payload.Format) (payload.Payload, error) {
	if value.Format() != payload.Lua || format != payload.Golang {
		return nil, errors.New("unsupported transcoding")
	}
	return payload.New(value.Data()), nil
}

func endpointNode(t *testing.T) (context.Context, *relaysys.Node, *relaysys.Router, topapi.PIDRegistry) {
	t.Helper()
	node := relaysys.NewNode("owner")
	router := relaysys.NewRouter(node, nil)
	names := topologysys.NewPIDRegistry()
	ctx := ctxapi.WithAppContext(context.Background(), ctxapi.NewAppContext())
	ctx = relay.WithNode(ctx, node)
	ctx = relay.WithRouter(ctx, router)
	ctx = topapi.WithRegistry(ctx, names)
	ctx = payload.WithTranscoder(ctx, luaTranscoder{})
	return ctx, node, router, names
}

// The node supervisor sees the endpoint's own node and host as the sender, and
// its reply reaches the endpoint through ordinary node routing.
func TestEndpointExchangesControlWithTheNodeSupervisor(t *testing.T) {
	ctx, node, router, names := endpointNode(t)
	requests := make(chan Message, 1)
	if err := node.RegisterHost("bee.hive.service:supervisor_host", cancellableCapture{requestCapture{requests}}); err != nil {
		t.Fatal(err)
	}
	supervisor := pid.PID{Node: "owner", Host: "bee.hive.service:supervisor_host", UniqID: "supervisor"}
	if _, err := names.Register("bee.hive.supervisor", supervisor); err != nil {
		t.Fatal(err)
	}
	endpoint, err := OpenEndpoint(ctx, "bee.hive:join_host")
	if err != nil {
		t.Fatal(err)
	}
	defer endpoint.Close()
	if _, err := OpenEndpoint(ctx, "bee.hive:join_host"); err == nil {
		t.Fatal("a second endpoint took a registered host")
	}
	deadline, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	found, err := endpoint.OwnerSupervisor(deadline)
	if err != nil || found != supervisor {
		t.Fatalf("supervisor = %v, %v", found, err)
	}
	if err := endpoint.Send(deadline, found, "bee.hive.request", []byte(`{"request_id":"r1"}`)); err != nil {
		t.Fatal(err)
	}
	request := <-requests
	if request.From != endpoint.PID() || request.From.Host != "bee.hive:join_host" || string(request.Body) != `{"request_id":"r1"}` {
		t.Fatalf("supervisor saw %+v", request)
	}
	reply := relay.NewPackage(supervisor, endpoint.PID(), "bee.hive.reply", payload.NewPayload(map[string]any{"request_id": "r1", "ok": true}, payload.Lua))
	if err := router.Send(reply); err != nil {
		t.Fatal(err)
	}
	received, err := endpoint.Receive(deadline)
	if err != nil || received.From != supervisor || received.Topic != "bee.hive.reply" || string(received.Body) != `{"ok":true,"request_id":"r1"}` {
		t.Fatalf("endpoint received %+v, %v", received, err)
	}
	// A package claiming another node's sender is not kept.
	foreign := relay.NewPackage(pid.PID{Node: "elsewhere", Host: "bee.hive.service:supervisor_host", UniqID: "x"}, endpoint.PID(), "bee.hive.reply", payload.New(map[string]any{"ok": true}))
	if err := router.Send(foreign); err != nil {
		t.Fatal(err)
	}
	short, stop := context.WithTimeout(ctx, 200*time.Millisecond)
	defer stop()
	if _, err := endpoint.Receive(short); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("foreign sender reached the endpoint: %v", err)
	}
	endpoint.Close()
	if _, err := endpoint.Receive(ctx); !errors.Is(err, ErrActorEnded) {
		t.Fatalf("closed endpoint receive = %v", err)
	}
	reopened, err := OpenEndpoint(ctx, "bee.hive:join_host")
	if err != nil {
		t.Fatalf("closed endpoint kept its host: %v", err)
	}
	reopened.Close()
}
