//go:build meshclient

// SPDX-License-Identifier: MIT

package localowner

import (
	"errors"

	"github.com/wippyai/bee/native/hive/rendezvous"
	"github.com/wippyai/runtime/api/attrs"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/api/registry"
	"github.com/wippyai/runtime/api/security"
)

const ClientAction = "bee.desktop.local_client"

// ClientPolicy is selected by the compiled host for the Hive supervisor only.
// The resource must be the native message sender, never a PID from its payload.
// It permits consideration for desktop admission, not a mount or input grant.
// This policy is bound to one prepared owner execution and is not published in
// the registry. Knowing its ID or importing a module cannot acquire it.
func (c *Component) ClientPolicy() (security.Policy, error) {
	c.mu.Lock()
	state := c.state
	c.mu.Unlock()
	if state == nil || state.ctx.Err() != nil {
		return nil, errors.New("local client policy requires a live prepared owner")
	}
	enrollment, err := rendezvous.NewEnrollment(state.directory)
	if err != nil {
		return nil, err
	}
	return &clientPolicy{state: state, enrollment: enrollment, owner: c.options.Node}, nil
}

type clientPolicy struct {
	state      *prepared
	enrollment *rendezvous.Enrollment
	owner      string
}

func (*clientPolicy) ID() registry.ID {
	return registry.ParseID("bee.hive:local_client_policy")
}

func (p *clientPolicy) Evaluate(actor security.Actor, action, resource string, _ attrs.Bag) security.Result {
	if action != ClientAction {
		return security.Undefined
	}
	if actor.ID != "bee.hive.supervisor" || p.state.ctx.Err() != nil {
		return security.Deny
	}
	sender, err := pid.ParsePID(resource)
	if err != nil || sender.Node == "" || sender.Node == p.owner || sender.Host != "bee.client:native" || sender.UniqID == "" {
		return security.Deny
	}
	// Enrollment is local OS-account authority. Discovery and membership alone
	// never satisfy this check. Resolve also fences owner execution replacement.
	if _, ok := p.enrollment.Resolve(p.state.ctx, p.state.execution, sender.Node); !ok {
		return security.Deny
	}
	return security.Allow
}
