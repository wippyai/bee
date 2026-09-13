// SPDX-License-Identifier: MIT

package docker

import (
	"context"
	"errors"
	"strings"

	"github.com/moby/moby/client"
	"github.com/wippyai/runtime/api/boot"
	luaboot "github.com/wippyai/runtime/boot/components/runtime/lua"
)

// ConfiguredComponent is the zero-argument builder factory for local Docker.
// The boot host selects bee.docker.reference and bee.docker.host (an absolute
// Unix socket URL). It owns the resulting client until component shutdown.
// Loading registers the module without connecting to Docker, even if the
// configured socket does not exist. This factory grants no application access.
func ConfiguredComponent() boot.Component {
	var cli *client.Client
	var loaded boot.Component
	var stopped bool
	return boot.New(boot.P{
		Name:      componentName,
		DependsOn: []boot.Name{luaboot.EngineName, luaboot.ExecName},
		Load: func(ctx context.Context) (context.Context, error) {
			if stopped {
				return ctx, errors.New("Docker component has stopped")
			}
			if loaded != nil {
				return loaded.Load(ctx)
			}
			cfg := boot.GetConfig(ctx)
			if cfg == nil {
				return ctx, errors.New("Docker component requires host configuration")
			}
			sub := cfg.Sub("bee").Sub("docker")
			host := sub.GetString("host", "")
			if !strings.HasPrefix(host, "unix:///") || len(host) <= len("unix:///") || strings.ContainsAny(host, "\x00\r\n?#") {
				return ctx, errors.New("Docker component requires an absolute Unix socket URL")
			}
			candidate, err := client.New(client.WithHost(host))
			if err != nil {
				return ctx, errors.New("Docker component has invalid client configuration")
			}
			component, err := Component(sub.GetString("reference", ""), candidate)
			if err != nil {
				_ = candidate.Close()
				return ctx, err
			}
			next, err := component.Load(ctx)
			if err != nil {
				_ = candidate.Close()
				return ctx, err
			}
			cli, loaded = candidate, component
			return next, nil
		},
		Stop: func(context.Context) error {
			stopped = true
			if cli == nil {
				return nil
			}
			err := cli.Close()
			cli = nil
			return err
		},
	})
}
