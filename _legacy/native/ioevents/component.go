// SPDX-License-Identifier: MIT

package ioevents

import (
	"context"
	"fmt"

	"github.com/wippyai/runtime/api/boot"
	"github.com/wippyai/runtime/api/dispatcher"
	"github.com/wippyai/runtime/boot/components/dispatchers"
	luaboot "github.com/wippyai/runtime/boot/components/runtime/lua"
)

// Component installs the I/O events module and its native command handler.
func Component() boot.Component {
	manager := NewManager()
	return boot.New(boot.P{
		Name: "bee.ioevents", DependsOn: []boot.Name{luaboot.EngineName, dispatchers.DispatcherName},
		Load: func(ctx context.Context) (context.Context, error) {
			registrar := dispatcher.GetRegistrar(ctx)
			code := luaboot.GetCodeManager(ctx)
			if registrar == nil || code == nil {
				return ctx, fmt.Errorf("I/O events require Lua and the command dispatcher")
			}
			if registrar.Has(watchCommand) {
				return ctx, fmt.Errorf("I/O events command is already registered")
			}
			registrar.Register(watchCommand, manager)
			return ctx, luaboot.AddModules(ctx, code, Module)
		},
		Stop: manager.Stop,
	})
}
