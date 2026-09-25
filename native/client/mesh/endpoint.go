//go:build meshclient

// SPDX-License-Identifier: MIT
package mesh

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"sync"

	"github.com/wippyai/runtime/api/payload"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/api/relay"
	topapi "github.com/wippyai/runtime/api/topology"
)

// Endpoint is a native sender inside a running node, on a host the node's own
// native composition registers. The runtime routes a reply to its PID only to
// this receiver, and a receiving process sees the endpoint's node and host as
// the runtime-derived sender, so the host name is the endpoint's identity. No
// Lua process can run on that host.
type Endpoint struct {
	id      pid.PID
	router  relay.ContextSender
	names   topapi.PIDRegistry
	codec   payload.Transcoder
	inbox   chan Message
	ctx     context.Context
	cancel  context.CancelFunc
	release context.CancelFunc
	once    sync.Once
}

// OpenEndpoint registers host on the node of ctx and returns its endpoint. The
// host must not already be registered. Close releases it.
func OpenEndpoint(ctx context.Context, host pid.HostID) (*Endpoint, error) {
	if ctx == nil || host == "" {
		return nil, errors.New("mesh endpoint: context and host are required")
	}
	node := relay.GetNode(ctx)
	registrar, owned := node.(relay.OwnedHostRegistrar)
	router, cancellable := relay.GetRouter(ctx).(relay.ContextSender)
	names := topapi.GetRegistry(ctx)
	codec := payload.GetTranscoder(ctx)
	if node == nil || !owned || !cancellable || names == nil || codec == nil {
		return nil, errors.New("mesh endpoint: node routing, names and transcoding are unavailable")
	}
	var unique [16]byte
	if _, err := rand.Read(unique[:]); err != nil {
		return nil, err
	}
	lifetime, cancel := context.WithCancel(context.WithoutCancel(ctx))
	endpoint := &Endpoint{
		id:     pid.PID{Node: node.ID(), Host: host, UniqID: hex.EncodeToString(unique[:])},
		router: router, names: names, codec: codec, inbox: make(chan Message, maxMessages), ctx: lifetime, cancel: cancel,
	}
	release, err := registrar.RegisterOwnedHost(host, endpointReceiver{endpoint})
	if err != nil {
		cancel()
		return nil, err
	}
	endpoint.release = release
	return endpoint, nil
}

// Close unregisters the host and ends pending receives.
func (e *Endpoint) Close() {
	e.once.Do(func() {
		e.release()
		e.cancel()
	})
}

func (e *Endpoint) PID() pid.PID { return e.id }

// endpointReceiver is the relay.Receiver the node delivers to. It keeps
// bounded JSON control messages addressed to the endpoint from processes of
// its own node. A local process sends in its own format, such as Lua values,
// which the node's transcoder converts to Go values before the bounds apply.
type endpointReceiver struct{ e *Endpoint }

// SendContext delivers without blocking, so cancellation never waits on it.
func (r endpointReceiver) SendContext(_ context.Context, pkg *relay.Package) error {
	return r.Send(pkg)
}

func (r endpointReceiver) Send(pkg *relay.Package) error {
	e := r.e
	if pkg == nil {
		return nil
	}
	defer relay.ReleasePackage(pkg)
	if !samePID(pkg.Target, e.id) || pkg.Source.Node != e.id.Node || e.ctx.Err() != nil {
		return nil
	}
	for _, message := range pkg.Messages {
		if message == nil || len(message.Payloads) != 1 || message.Payloads[0] == nil {
			continue
		}
		value := message.Payloads[0]
		if value.Format() != payload.JSON && value.Format() != payload.Golang {
			converted, err := e.codec.Transcode(value, payload.Golang)
			if err != nil {
				continue
			}
			value = converted
		}
		body, ok := controlBody(value)
		if !ok || !validBody(message.Topic, body) {
			continue
		}
		select {
		case e.inbox <- Message{From: pkg.Source, Topic: message.Topic, Body: bytes.Clone(body)}:
		default:
			return ErrInboxFull
		}
	}
	return nil
}

// OwnerSupervisor resolves the node's own Hive supervisor by its local name.
func (e *Endpoint) OwnerSupervisor(ctx context.Context) (pid.PID, error) {
	if ctx == nil {
		return pid.PID{}, errors.New("mesh endpoint: missing lookup context")
	}
	if err := ctx.Err(); err != nil {
		return pid.PID{}, err
	}
	found, ok := e.names.Lookup("bee.hive.supervisor")
	if !ok || found.Node != e.id.Node || found.Host != "bee.hive.service:supervisor_host" || found.UniqID == "" {
		return pid.PID{}, errors.New("mesh endpoint: node supervisor is not registered")
	}
	return found, nil
}

// Send delivers one bounded JSON message from the endpoint to a process of its
// own node and never replays it.
func (e *Endpoint) Send(ctx context.Context, target pid.PID, topic string, body []byte) error {
	if ctx == nil {
		return errors.New("mesh endpoint: missing send context")
	}
	if err := e.ctx.Err(); err != nil {
		return err
	}
	if target.Node != e.id.Node || target.Host == "" || target.UniqID == "" || !validBody(topic, body) {
		return errors.New("mesh endpoint: invalid local request")
	}
	pkg := relay.NewPackage(e.id, target, topic, payload.NewPayload(bytes.Clone(body), payload.JSON))
	message := pkg.Messages[0]
	message.PayloadBytes = int64(len(body))
	message.MaxBytes = maxMessages * maxMessageBytes
	message.MaxItems = maxMessages
	if err := e.router.SendContext(ctx, pkg); err != nil {
		relay.ReleasePackage(pkg)
		return err
	}
	return nil
}

// Receive returns the next kept message, or the end of ctx or the endpoint.
func (e *Endpoint) Receive(ctx context.Context) (Message, error) {
	if ctx == nil {
		return Message{}, errors.New("mesh endpoint: missing receive context")
	}
	select {
	case <-ctx.Done():
		return Message{}, ctx.Err()
	case <-e.ctx.Done():
		return Message{}, ErrActorEnded
	case message := <-e.inbox:
		return message, nil
	}
}
