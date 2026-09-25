//go:build meshclient

// SPDX-License-Identifier: MIT

// Package hive speaks Bee's existing Hive call/reply protocol through a native
// physical-client actor. It owns no transport and grants no application rights.
package hive

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/wippyai/bee/native/client/mesh"
	"github.com/wippyai/runtime/api/pid"
)

const Revision = "bee.hive@1"
const requestTopic = "bee.hive.request"
const replyTopic = "bee.hive.reply"
const maxBytes = 16 * 1024

var ErrProtocol = errors.New("Hive reply violates the native client contract")
var ErrOwner = errors.New("Hive owner changed or client lifetime ended")

// UnknownOutcome means the request was accepted by transport but no trustworthy
// reply arrived. It never authorizes a replay. Operation and Key are the identity
// an operation-specific status query may use for reconciliation.
type UnknownOutcome struct {
	Operation, Key string
	Cause          error
}

func (e *UnknownOutcome) Error() string {
	return "Hive operation outcome is unknown: " + e.Cause.Error()
}
func (e *UnknownOutcome) Unwrap() error { return e.Cause }

type Owner struct {
	Node     string `json:"node_id"`
	Service  string `json:"service_id"`
	Resource string `json:"resource_ref,omitempty"`
}
type Operation struct {
	Owner Owner
	Ref   string
	// Key is mandatory: the caller retains it across an uncertain outcome.
	Key   string
	Input json.RawMessage
}
type wireCall struct {
	Revision string `json:"protocol_revision"`
	ID       string `json:"request_id"`
	Key      string `json:"idempotency_key"`
	Owner    Owner  `json:"owner_ref"`
	Target   struct {
		Ref string `json:"operation_ref"`
	} `json:"target"`
	Input    json.RawMessage `json:"input"`
	Deadline string          `json:"deadline"`
}

// Transport is a native sender with one inbox: a physical-client actor or an
// endpoint inside the owner node.
type Transport interface {
	OwnerSupervisor(context.Context) (pid.PID, error)
	Send(context.Context, pid.PID, string, []byte) error
	Receive(context.Context) (mesh.Message, error)
}

// Client has one inbox consumer and serializes calls with cancellable admission.
// New must receive the actor belonging to the physical client's runtime frame.
// A Client pins its first accepted supervisor; owner replacement requires a new
// Client and requires operation-specific admission again.
type Client struct {
	actor      Transport
	owner      string
	gate       chan struct{}
	supervisor pid.PID
	ctx        context.Context
	failed     error
}

func New(lifetime context.Context, actor *mesh.Actor, ownerNode string) (*Client, error) {
	if actor == nil {
		return nil, errors.New("invalid native Hive client")
	}
	return NewClient(lifetime, actor, ownerNode)
}

// NewClient binds a client to any native transport of the owner node.
func NewClient(lifetime context.Context, transport Transport, ownerNode string) (*Client, error) {
	if lifetime == nil || lifetime.Done() == nil || transport == nil || !identifier(ownerNode) {
		return nil, errors.New("invalid native Hive client")
	}
	return &Client{actor: transport, ctx: lifetime, owner: ownerNode, gate: make(chan struct{}, 1)}, nil
}

func live(lifetime <-chan struct{}) bool {
	if lifetime == nil {
		return false
	}
	select {
	case <-lifetime:
		return false
	default:
		return true
	}
}
func samePID(a, b pid.PID) bool { return a.Node == b.Node && a.Host == b.Host && a.UniqID == b.UniqID }

// Call uses the existing bee.hive@1 Call envelope. A successful transport send
// is not operation completion. It sends once, validates the exact supervisor,
// request, schema and actor lifetime, and never retries. Value remains encoded
// until the caller applies the selected operation's typed result decoder.
func (c *Client) Call(ctx context.Context, operation Operation) (Reply, error) {
	if ctx == nil || c == nil || c.actor == nil || c.gate == nil || c.ctx == nil {
		return Reply{}, errors.New("invalid Hive call context")
	}
	// Bound both waiting for this client and waiting for the owner.
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	stop := context.AfterFunc(c.ctx, cancel)
	defer stop()
	select {
	case c.gate <- struct{}{}:
		defer func() { <-c.gate }()
	case <-ctx.Done():
		return Reply{}, ctx.Err()
	}
	if err := ctx.Err(); err != nil {
		return Reply{}, err
	}
	if c.failed != nil {
		return Reply{}, c.failed
	}
	if c.ctx.Err() != nil {
		c.failed = ErrOwner
		return Reply{}, ErrOwner
	}
	operation.Input = bytes.Clone(operation.Input)
	if !identifier(operation.Owner.Node) || !identifier(operation.Owner.Service) ||
		(operation.Owner.Resource != "" && !identifier(operation.Owner.Resource)) || !identifier(operation.Ref) ||
		!identifier(operation.Key) || !object(operation.Input) {
		return Reply{}, errors.New("invalid Hive operation")
	}
	supervisor, err := c.actor.OwnerSupervisor(ctx)
	if err != nil {
		return Reply{}, err
	}
	if supervisor.Node != c.owner || supervisor.Host != "bee.hive.service:supervisor_host" || supervisor.UniqID == "" {
		return Reply{}, ErrProtocol
	}
	if c.supervisor.UniqID != "" && !samePID(c.supervisor, supervisor) {
		c.failed = ErrOwner
		return Reply{}, ErrOwner
	}
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return Reply{}, err
	}
	deadline, _ := ctx.Deadline()
	call := wireCall{Revision: Revision, ID: hex.EncodeToString(nonce[:]), Key: operation.Key, Owner: operation.Owner,
		Input: operation.Input, Deadline: deadline.UTC().Format("2006-01-02T15:04:05.000Z")}
	call.Target.Ref = operation.Ref
	body, err := json.Marshal(call)
	if err != nil || len(body) > maxBytes {
		return Reply{}, errors.New("Hive request exceeds native control limit")
	}
	if err := c.actor.Send(ctx, supervisor, requestTopic, body); err != nil {
		return Reply{}, err
	}
	uncertain := func(cause error) (Reply, error) {
		return Reply{}, &UnknownOutcome{Operation: operation.Ref, Key: operation.Key, Cause: cause}
	}
	for {
		message, err := c.actor.Receive(ctx)
		if err != nil {
			return uncertain(err)
		}
		if err := ctx.Err(); err != nil {
			return uncertain(err)
		}
		if message.Topic != replyTopic || !samePID(message.From, supervisor) {
			continue
		}
		reply, err := decodeReply(message.Body)
		if err != nil {
			c.failed = ErrProtocol
			return uncertain(fmt.Errorf("%w: %v", ErrProtocol, err))
		}
		if reply.ID != call.ID {
			continue
		}
		if reply.Fault != nil && reply.Fault.Identity != nil && (reply.Fault.Identity.Operation != operation.Ref || reply.Fault.Identity.Key != operation.Key) {
			c.failed = ErrProtocol
			return uncertain(ErrProtocol)
		}
		if err := ctx.Err(); err != nil {
			return uncertain(err)
		}
		current, lookupErr := c.actor.OwnerSupervisor(ctx)
		if lookupErr != nil || !samePID(current, supervisor) {
			c.failed = ErrOwner
			return uncertain(ErrOwner)
		}
		if err := ctx.Err(); err != nil {
			return uncertain(err)
		}
		if err := c.ctx.Err(); err != nil {
			return uncertain(err)
		}
		reply.lifetime = c.ctx.Done()
		c.supervisor = supervisor
		return reply, nil
	}
}

// UnmarshalJSON preserves absent optional resource identity versus an explicit
// empty value and rejects case aliases at this authority boundary.
func (o *Owner) UnmarshalJSON(raw []byte) error {
	var fields map[string]json.RawMessage
	if !object(raw) || strict(raw, &fields) != nil {
		return ErrProtocol
	}
	for name := range fields {
		if name != "node_id" && name != "service_id" && name != "resource_ref" {
			return ErrProtocol
		}
	}
	var value Owner
	if json.Unmarshal(fields["node_id"], &value.Node) != nil || !identifier(value.Node) ||
		json.Unmarshal(fields["service_id"], &value.Service) != nil || !identifier(value.Service) {
		return ErrProtocol
	}
	if resource := fields["resource_ref"]; present(resource) {
		if json.Unmarshal(resource, &value.Resource) != nil || !identifier(value.Resource) {
			return ErrProtocol
		}
	}
	*o = value
	return nil
}
