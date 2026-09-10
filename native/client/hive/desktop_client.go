//go:build meshclient

// SPDX-License-Identifier: MIT
package hive

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/wippyai/bee/native/client/mesh"
	"github.com/wippyai/runtime/api/pid"
)

// Desktop owns the actor's Hive inbox and binds all desktop operations to the
// selected execution and the actor's actual recipient identity. It owns no
// transport, viewport, database or automatic retry policy.
type Desktop struct {
	client    *Client
	owner     string
	execution string
	recipient pid.PID
}

// Rejected is a definite Hive refusal. Retryable describes the owner's response;
// it never causes this binding to repeat an operation.
type Rejected struct{ Fault Fault }

func (e *Rejected) Error() string { return e.Fault.Code + ": " + e.Fault.Message }

func NewDesktop(lifetime context.Context, actor *mesh.Actor, ownerNode, execution string) (*Desktop, error) {
	if actor == nil || !durableID(execution) {
		return nil, errors.New("invalid desktop owner execution")
	}
	recipient := actor.PID()
	if recipient.Node == "" || recipient.Host != "bee.client:native" || recipient.UniqID == "" {
		return nil, errors.New("desktop requires a native physical-client actor")
	}
	client, err := New(lifetime, actor, ownerNode)
	if err != nil {
		return nil, err
	}
	return &Desktop{client: client, owner: ownerNode, execution: execution, recipient: recipient}, nil
}
func (d *Desktop) call(ctx context.Context, operation, key string, input any) (Reply, error) {
	if d == nil || d.client == nil {
		return Reply{}, errors.New("desktop client unavailable")
	}
	raw, err := json.Marshal(input)
	if err != nil {
		return Reply{}, err
	}
	reply, err := d.client.Call(ctx, Operation{Owner: Owner{Node: d.owner, Service: DesktopService}, Ref: operation, Key: key, Input: raw})
	if err != nil {
		return Reply{}, err
	}
	if !reply.OK {
		if reply.Fault == nil {
			return Reply{}, ErrProtocol
		}
		rejected := &Rejected{Fault: *reply.Fault}
		if reply.Fault.Code == "UNCERTAIN" {
			return Reply{}, &UnknownOutcome{Operation: operation, Key: key, Cause: rejected}
		}
		return Reply{}, rejected
	}
	return reply, nil
}
func (d *Desktop) List(ctx context.Context, key string) (DesktopCatalog, error) {
	if d == nil {
		return DesktopCatalog{}, errors.New("desktop client unavailable")
	}
	reply, err := d.call(ctx, DesktopList, key, struct {
		Execution string `json:"owner_execution"`
	}{d.execution})
	if err != nil {
		return DesktopCatalog{}, err
	}
	return DecodeDesktopCatalog(reply, d.execution)
}
func (d *Desktop) Attach(ctx context.Context, key, workspace, desktop string, mode DesktopMode) (DesktopMount, error) {
	if d == nil {
		return DesktopMount{}, errors.New("desktop client unavailable")
	}
	selected := DesktopSelection{Execution: d.execution, Workspace: workspace, Desktop: desktop}
	if !selected.valid() || mode != Control && mode != Observe {
		return DesktopMount{}, errors.New("invalid desktop selection or mode")
	}
	input := struct {
		DesktopSelection
		Mode DesktopMode `json:"mode"`
	}{selected, mode}
	reply, err := d.call(ctx, DesktopAttach, key, input)
	if err != nil {
		return DesktopMount{}, err
	}
	mounted, err := DecodeDesktopMount(reply, selected, d.recipient, mode, time.Now())
	if err != nil {
		// The owner replied success: attachment may exist even though the returned
		// grant cannot be used. Preserve the caller's retained operation identity.
		return DesktopMount{}, &UnknownOutcome{Operation: DesktopAttach, Key: key, Cause: err}
	}
	mounted.owner = d.owner
	return mounted, nil
}
func (d *Desktop) Detach(ctx context.Context, key string, mounted DesktopMount) error {
	if d == nil || !mounted.Selection.valid() || mounted.Selection.Execution != d.execution || mounted.owner != d.owner ||
		!samePID(mounted.Recipient, d.recipient) || !identifier(mounted.Session) || !live(mounted.lifetime) {
		return errors.New("desktop session unavailable or belongs to another recipient")
	}
	input := struct {
		DesktopSelection
		Session string `json:"session_id"`
	}{mounted.Selection, mounted.Session}
	reply, err := d.call(ctx, DesktopDetach, key, input)
	if err != nil {
		return err
	}
	if err := DecodeDesktopDetached(reply, mounted.Selection); err != nil {
		return &UnknownOutcome{Operation: DesktopDetach, Key: key, Cause: err}
	}
	return nil
}

// Create allocates the caller-retained identity. Retry uses that same identity;
// it does not activate a desktop, open a viewport, or grant control.
func (d *Desktop) Create(ctx context.Context, workspace, desktop string) (DesktopSelection, error) {
	if d == nil {
		return DesktopSelection{}, errors.New("desktop client unavailable")
	}
	selected := DesktopSelection{Execution: d.execution, Workspace: workspace, Desktop: desktop}
	if !selected.valid() {
		return DesktopSelection{}, errors.New("invalid desktop identity")
	}
	reply, err := d.call(ctx, DesktopCreate, desktop, selected)
	if err != nil {
		return DesktopSelection{}, err
	}
	if err := DecodeDesktopCreated(reply, selected); err != nil {
		return DesktopSelection{}, &UnknownOutcome{Operation: DesktopCreate, Key: desktop, Cause: err}
	}
	return selected, nil
}
