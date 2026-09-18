// SPDX-License-Identifier: MIT

package service

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"time"

	ctxapi "github.com/wippyai/runtime/api/context"
	"github.com/wippyai/runtime/api/event"
	"github.com/wippyai/runtime/api/payload"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/api/process"
	"github.com/wippyai/runtime/api/registry"
	"github.com/wippyai/runtime/api/security"
	supervisorapi "github.com/wippyai/runtime/api/service/supervisor"
	"github.com/wippyai/runtime/api/supervisor"
	svc "github.com/wippyai/runtime/service/supervisor"
)

// hiveService wraps the runtime supervisor.Service to enforce fail-closed verification
// of required resources upon service startup.
type hiveService struct {
	*svc.Service
	cfg Config
}

var _ supervisor.Service = (*hiveService)(nil)

func (s *hiveService) Start(ctx context.Context) (<-chan any, error) {
	// Required resources looked up fail closed.
	// Nil registry must not skip required validation.
	reg := registry.GetRegistry(ctx)
	if reg == nil {
		return nil, fmt.Errorf("%w: registry not available in context", supervisor.ErrExit)
	}

	procEntry, err := reg.GetEntry(registry.ParseID(ProcessID))
	if err != nil {
		return nil, fmt.Errorf("%w: required process resource %s not found in registry: %v", supervisor.ErrExit, ProcessID, err)
	}
	if procEntry.Kind != "process.lua" {
		return nil, fmt.Errorf("%w: required process resource %s has unexpected kind %q (expected process.lua)", supervisor.ErrExit, ProcessID, procEntry.Kind)
	}

	hostEntry, err := reg.GetEntry(registry.ParseID(HostID))
	if err != nil {
		return nil, fmt.Errorf("%w: required host resource %s not found in registry: %v", supervisor.ErrExit, HostID, err)
	}
	if hostEntry.Kind != "process.host" {
		return nil, fmt.Errorf("%w: required host resource %s has unexpected kind %q (expected process.host)", supervisor.ErrExit, HostID, hostEntry.Kind)
	}

	for _, pol := range s.cfg.Policies {
		polEntry, err := reg.GetEntry(registry.ParseID(pol))
		if err != nil {
			return nil, fmt.Errorf("%w: required policy resource %s not found in registry: %v", supervisor.ErrExit, pol, err)
		}
		if polEntry.Kind != "security.policy" && polEntry.Kind != "security.policy.expr" {
			return nil, fmt.Errorf("%w: required policy resource %s has unexpected kind %q (expected security.policy)", supervisor.ErrExit, pol, polEntry.Kind)
		}
	}

	if s.cfg.Desktop != nil && s.cfg.Desktop.ClientPolicy != nil {
		ctx, err = clientPolicyContext(ctx, s.cfg.Desktop.ClientPolicy)
		if err != nil {
			return nil, err
		}
	}
	return s.Service.Start(ctx)
}

// The lifecycle's frame is sealed and may be reused on restart. Fork it so
// host-selected desktop authority never changes a parent or sibling service.
func clientPolicyContext(ctx context.Context, policy security.Policy) (context.Context, error) {
	actor, ok := security.GetActor(ctx)
	if !ok || actor.ID != ActorID {
		return nil, errors.New("local client policy requires supervisor actor")
	}
	child, frame := ctxapi.ForkFrameContext(ctx)
	if err := security.WithPolicy(child, policy); err != nil {
		return nil, err
	}
	frame.Seal()
	return child, nil
}

func (s *hiveService) Stop(ctx context.Context) error {
	return s.Service.Stop(ctx)
}

type activationListener struct {
	cfg    Config
	bus    event.Bus
	dtt    payload.Transcoder
	pidGen process.PIDGenerator
}

var _ registry.EntryListener = (*activationListener)(nil)

func (l *activationListener) validateEntry(ctx context.Context, entry registry.Entry) error {
	if entry.ID.String() != ActivationID {
		return fmt.Errorf("unapproved activation identity: %s (expected %s)", entry.ID, ActivationID)
	}
	if entry.Kind != ActivationKind {
		return fmt.Errorf("unapproved activation kind: %s (expected %s)", entry.Kind, ActivationKind)
	}

	// Registry activation entry Data strictly empty (nil/empty object supported through real decoder),
	// reject unrecognized payload/fields; registry cannot choose input/process/host/actor/policies.
	if entry.Data != nil {
		var fields map[string]any
		dtt := l.dtt
		if dtt == nil {
			dtt = payload.GetTranscoder(ctx)
		}
		if dtt != nil {
			if err := dtt.Unmarshal(entry.Data, &fields); err != nil {
				return fmt.Errorf("invalid activation payload: %w", err)
			}
		} else if raw, ok := entry.Data.Data().(map[string]any); ok {
			fields = raw
		}
		if len(fields) > 0 {
			fieldNames := make([]string, 0, len(fields))
			for k := range fields {
				fieldNames = append(fieldNames, k)
			}
			sort.Strings(fieldNames)
			return fmt.Errorf("activation entry Data must be strictly empty; unrecognized payload fields: %v", fieldNames)
		}
	}
	return nil
}

func (l *activationListener) createSupervisedService(entryID registry.ID) (supervisor.Service, supervisor.LifecycleConfig) {
	inputNodes := make([]string, len(l.cfg.ConfiguredNodes))
	copy(inputNodes, l.cfg.ConfiguredNodes)

	secPolicies := make([]registry.ID, len(l.cfg.Policies))
	for i, pol := range l.cfg.Policies {
		secPolicies[i] = registry.ParseID(pol)
	}

	input := map[string]any{"configured_nodes": inputNodes}
	requires := []string{HostID}
	if l.cfg.Desktop != nil {
		input["desktop"] = l.cfg.Desktop.input()
		requires = append(requires, "bee:workers")
	}
	svcConfig := supervisorapi.ServiceConfig{
		Process: registry.ParseID(ProcessID),
		HostID:  pid.HostID(HostID),
		Input:   []any{input},
		Lifecycle: supervisor.LifecycleConfig{
			AutoStart:    true,
			Requires:     requires,
			StartTimeout: 10 * time.Second,
			StopTimeout:  5 * time.Second,
			Security: &security.Config{
				Actor: security.Actor{
					ID: ActorID,
				},
				Policies: secPolicies,
			},
		},
	}

	rawService := svc.NewService(entryID, svcConfig, l.pidGen)
	serviceInstance := &hiveService{
		Service: rawService,
		cfg:     l.cfg,
	}
	return serviceInstance, svcConfig.Lifecycle
}

// Add implements registry.EntryListener.
func (l *activationListener) Add(ctx context.Context, entry registry.Entry) error {
	if err := l.validateEntry(ctx, entry); err != nil {
		return err
	}

	// Disabled accepts inert activation, no service registered.
	if !l.cfg.Enabled {
		return nil
	}

	serviceInstance, lifecycleCfg := l.createSupervisedService(entry.ID)

	bus := l.bus
	if bus == nil {
		bus = event.GetBus(ctx)
	}
	if bus == nil {
		return errors.New("event bus not available")
	}

	bus.Send(ctx, event.Event{
		System: supervisor.System,
		Kind:   supervisor.ServiceRegister,
		Path:   entry.ID.String(),
		Data: &supervisor.Entry{
			Service: serviceInstance,
			Config:  lifecycleCfg,
		},
	})

	return nil
}

// Update implements registry.EntryListener.
// It performs remove and register within the CURRENT registry transaction using verified native
// same-ID replacement. It does not use Manager.Update (an ignored lifecycle event).
func (l *activationListener) Update(ctx context.Context, entry registry.Entry) error {
	if err := l.validateEntry(ctx, entry); err != nil {
		return err
	}

	if !l.cfg.Enabled {
		return nil
	}

	bus := l.bus
	if bus == nil {
		bus = event.GetBus(ctx)
	}
	if bus == nil {
		return errors.New("event bus not available")
	}

	// Send ServiceRemove first to mark pending removal in current transaction
	bus.Send(ctx, event.Event{
		System: supervisor.System,
		Kind:   supervisor.ServiceRemove,
		Path:   entry.ID.String(),
	})

	// Create fresh service instance with clean channels and supervisor PID
	serviceInstance, lifecycleCfg := l.createSupervisedService(entry.ID)

	// Send ServiceRegister to record replacement in current transaction
	bus.Send(ctx, event.Event{
		System: supervisor.System,
		Kind:   supervisor.ServiceRegister,
		Path:   entry.ID.String(),
		Data: &supervisor.Entry{
			Service: serviceInstance,
			Config:  lifecycleCfg,
		},
	})

	return nil
}

// Delete implements registry.EntryListener.
func (l *activationListener) Delete(ctx context.Context, entry registry.Entry) error {
	if entry.ID.String() != ActivationID {
		return fmt.Errorf("unapproved activation identity: %s (expected %s)", entry.ID, ActivationID)
	}

	if !l.cfg.Enabled {
		return nil
	}

	bus := l.bus
	if bus == nil {
		bus = event.GetBus(ctx)
	}
	if bus == nil {
		return errors.New("event bus not available")
	}

	bus.Send(ctx, event.Event{
		System: supervisor.System,
		Kind:   supervisor.ServiceRemove,
		Path:   entry.ID.String(),
	})

	return nil
}
