// SPDX-License-Identifier: MIT

package service

import (
	"context"
	"errors"
	"fmt"

	"github.com/wippyai/runtime/api/boot"
	"github.com/wippyai/runtime/api/event"
	"github.com/wippyai/runtime/api/payload"
	"github.com/wippyai/runtime/api/process"
	"github.com/wippyai/runtime/api/registry"
	bootpkg "github.com/wippyai/runtime/boot"
	"github.com/wippyai/runtime/boot/components/core"
)

// New constructs a native Hive supervisor activation component.
// Configuration is validated and copied; enabled startup requires host-selected policies.
func New(cfg Config) (boot.Component, error) {
	cloned := cfg.clone()
	if err := cloned.Validate(); err != nil {
		return nil, err
	}

	listener := &activationListener{
		cfg: cloned,
	}

	comp := boot.New(boot.P{
		Name:      ComponentName,
		DependsOn: []boot.Name{core.SupervisorName},
		Load: func(ctx context.Context) (context.Context, error) {
			bus := event.GetBus(ctx)
			if bus == nil {
				return ctx, errors.New("event bus not available in context")
			}
			dtt := payload.GetTranscoder(ctx)
			if dtt == nil {
				return ctx, errors.New("payload transcoder not available in context")
			}
			pidGen := process.GetPIDGenerator(ctx)
			if pidGen == nil {
				return ctx, errors.New("PID generator not available in context")
			}
			handlers := bootpkg.GetHandlerRegistry(ctx)
			if handlers == nil {
				return ctx, errors.New("handler registry not available in context")
			}

			// Register dependency pattern on registry so topological sorting
			// respects metadata dependencies during loading.
			if reg := registry.GetRegistry(ctx); reg != nil {
				if err := reg.RegisterDependencyPattern(registry.DependencyPattern{
					Path:          "meta.depends_on",
					Description:   "Explicit dependencies in metadata",
					AllowWildcard: true,
				}); err != nil {
					return ctx, fmt.Errorf("failed to register dependency pattern: %w", err)
				}
			}

			listener.bus = bus
			listener.dtt = dtt
			listener.pidGen = pidGen

			handlers.RegisterListener(ActivationKind, listener)
			return ctx, nil
		},
	})

	return comp, nil
}
