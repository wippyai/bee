// SPDX-License-Identifier: MIT

package docker

import (
	"context"
	"errors"
	"fmt"

	"github.com/moby/moby/client"
	"github.com/wippyai/runtime/api/boot"
	luaapi "github.com/wippyai/runtime/api/runtime/lua"
	luaboot "github.com/wippyai/runtime/boot/components/runtime/lua"
)

const componentName = "bee.docker"

// Component composes the host-selected Docker client into the normal Wippy
// boot graph. The host owns cli and its lifetime; this component never creates
// a client, discovers a socket, or contacts the daemon.
func Component(daemonRef string, cli *client.Client) (boot.Component, error) {
	module, err := NewModule(daemonRef, cli)
	if err != nil {
		return nil, err
	}
	return componentWithModule(module), nil
}

func componentWithModule(module *luaapi.ModuleDef) boot.Component {
	return boot.New(boot.P{
		Name:      componentName,
		DependsOn: []boot.Name{luaboot.EngineName, luaboot.ExecName},
		Load: func(ctx context.Context) (context.Context, error) {
			manager := luaboot.GetCodeManager(ctx)
			if manager == nil {
				return ctx, errors.New("Docker component requires the Lua code manager")
			}

			for _, existing := range manager.GetModuleDefs() {
				if existing.Name != module.Name {
					continue
				}
				if existing == module {
					return ctx, nil
				}
				return ctx, fmt.Errorf("Docker module %q is already registered", module.Name)
			}

			if err := luaboot.AddModules(ctx, manager, module); err != nil {
				return ctx, err
			}
			return ctx, nil
		},
	})
}
