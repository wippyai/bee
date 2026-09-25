//go:build meshclient

// SPDX-License-Identifier: MIT
package mesh

import (
	"context"
	"errors"

	"github.com/wippyai/runtime/api/boot"
	clusterapi "github.com/wippyai/runtime/api/cluster"
	ctxapi "github.com/wippyai/runtime/api/context"
	eventapi "github.com/wippyai/runtime/api/event"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/api/relay"
	topapi "github.com/wippyai/runtime/api/topology"
	bootsys "github.com/wippyai/runtime/boot/components/system"
	stackpkg "github.com/wippyai/runtime/cluster"
	topologysys "github.com/wippyai/runtime/system/topology"
)

// prepareNames loads the standard runtime naming component before membership
// starts, so its delegate participates in the initial state exchange. The
// caller starts/stops it around the client callback, before stopping transport.
func prepareNames(ctx context.Context, stack *stackpkg.Stack, bus eventapi.Bus) (context.Context, boot.Component, error) {
	if ctx == nil || stack == nil || bus == nil {
		return nil, nil, errors.New("mesh client: invalid naming assembly")
	}
	root := ctxapi.WithAppContext(ctx, ctxapi.NewAppContext())
	root = clusterapi.WithMembership(root, stack.Membership)
	root = eventapi.WithBus(root, bus)
	root = relay.WithNode(root, stack.Node)
	root = relay.WithRouter(root, stack.Router)
	root = topapi.WithRegistry(root, topologysys.NewPIDRegistry())
	component := bootsys.EventualReg()
	root, err := component.Load(root)
	if err != nil {
		return nil, nil, err
	}
	return root, component, nil
}

// PinSupervisor records the owner's supervisor address the rendezvous
// descriptor published. A raft-disabled owner never registers the cluster-wide
// name, so a local client addresses the supervisor directly by node and process
// id. The address is still verified on every use: node, host and identity must
// match, and the supervisor authenticates the sender independently.
func (a *Actor) PinSupervisor(p pid.PID) { a.pinned = p }

// pinnedSupervisor returns the pinned address when it is a valid supervisor
// identity for this actor's owner.
func (a *Actor) pinnedSupervisor() (pid.PID, bool) {
	p := a.pinned
	if p.Node != a.owner || p.Host != "bee.hive_host:supervisor_host" || p.UniqID == "" {
		return pid.PID{}, false
	}
	return p, true
}

// OwnerSupervisor resolves the existing Hive name. Discovery supplies only an
// address; the caller must still verify the native sender, execution and admission replies.
// Absence is transient and never starts an owner or replays an operation.
func (a *Actor) OwnerSupervisor(ctx context.Context) (pid.PID, error) {
	if pinned, ok := a.pinnedSupervisor(); ok {
		return pinned, nil
	}
	if ctx == nil {
		return pid.PID{}, errors.New("mesh client: missing lookup context")
	}
	if err := ctx.Err(); err != nil {
		return pid.PID{}, err
	}
	if err := a.ctx.Err(); err != nil {
		return pid.PID{}, err
	}
	names := topapi.GetEventualRegistry(a.ctx)
	if names == nil {
		return pid.PID{}, errors.New("mesh client: native naming unavailable")
	}
	found, err := names.Lookup(ctx, "bee.hive_host.supervisor/"+a.owner)
	if err != nil {
		return pid.PID{}, err
	}
	if !found.Found {
		return pid.PID{}, errors.New("mesh client: owner supervisor not discovered")
	}
	if found.PID.Node != a.owner || found.PID.Host != "bee.hive_host:supervisor_host" || found.PID.UniqID == "" {
		return pid.PID{}, errors.New("mesh client: invalid owner supervisor address")
	}
	return found.PID, nil
}
