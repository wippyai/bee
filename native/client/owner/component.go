// SPDX-License-Identifier: MIT

package owner

import (
	"context"
	"fmt"

	"github.com/wippyai/runtime/api/boot"
	"github.com/wippyai/runtime/api/dispatcher"
	"github.com/wippyai/runtime/boot/components/dispatchers"
	luaboot "github.com/wippyai/runtime/boot/components/runtime/lua"
)

// Component installs the localdisplay Lua module and its dispatcher command handler.
func Component(acceptor Acceptor) boot.Component {
	return New(acceptor).Component()
}

// Component creates a boot.Component backed by this Manager instance.
func (m *Manager) Component() boot.Component {
	return boot.New(boot.P{
		Name:      "bee.localdisplay",
		DependsOn: []boot.Name{luaboot.EngineName, dispatchers.DispatcherName},
		Load: func(ctx context.Context) (context.Context, error) {
			registrar := dispatcher.GetRegistrar(ctx)
			code := luaboot.GetCodeManager(ctx)
			if registrar == nil || code == nil {
				return ctx, fmt.Errorf("localdisplay requires Lua and the command dispatcher")
			}
			if registrar.Has(acceptCommand) {
				return ctx, fmt.Errorf("localdisplay command is already registered")
			}
			registrar.Register(acceptCommand, m)
			return ctx, luaboot.AddModules(ctx, code, Module)
		},
		Stop: m.Stop,
	})
}
