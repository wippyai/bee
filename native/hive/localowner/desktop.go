//go:build meshclient

// SPDX-License-Identifier: MIT

package localowner

import (
	"context"
	"errors"
	"slices"

	"github.com/wippyai/bee/native/hive/service"
	"github.com/wippyai/runtime/api/boot"
	"github.com/wippyai/runtime/boot/components/core"
)

// DesktopService composes the existing Hive service with this owner's execution.
// Policies and the initial application come from the compiled launcher. Load
// runs after lock-held owner preparation; tooling remains disabled. The caller
// must also include this owner component and the protected activation entry.
func (c *Component) DesktopService(policies []string, application string) (boot.Component, error) {
	selected := slices.Clone(policies)
	if !slices.Contains(selected, service.DesktopHostPolicy) {
		return nil, errors.New("local desktop service requires explicit desktop host policy")
	}
	if _, err := service.New(service.Config{Enabled: true, Policies: selected}); err != nil {
		return nil, err
	}
	return boot.New(boot.P{
		Name:      service.ComponentName,
		DependsOn: []boot.Name{core.SupervisorName},
		Load: func(ctx context.Context) (context.Context, error) {
			c.mu.Lock()
			state := c.state
			c.mu.Unlock()
			cfg := service.Config{Policies: selected}
			if state != nil {
				policy, err := c.ClientPolicy()
				if err != nil {
					return ctx, err
				}
				cfg.Enabled = true
				cfg.Desktop = &service.DesktopConfig{
					Execution: state.execution, ExpiresAt: state.expires,
					ClientPolicy: policy, Application: application,
				}
			}
			component, err := service.New(cfg)
			if err != nil {
				return ctx, err
			}
			return component.Load(ctx)
		},
	}), nil
}
