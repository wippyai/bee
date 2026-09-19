// SPDX-License-Identifier: MIT

package docker

import (
	"errors"
	"strings"

	"github.com/moby/moby/client"
	lua "github.com/wippyai/go-lua"
	"github.com/wippyai/runtime/api/attrs"
	luaapi "github.com/wippyai/runtime/api/runtime/lua"
	secapi "github.com/wippyai/runtime/api/security"
	"github.com/wippyai/runtime/runtime/lua/engine/value"
	luaexec "github.com/wippyai/runtime/runtime/lua/modules/exec"
	"github.com/wippyai/runtime/runtime/security"
)

// NewModule binds one host-selected daemon. Lua callers cannot change its
// address or transport configuration. The host owns cli and its lifetime.
func NewModule(daemonRef string, cli *client.Client) (*luaapi.ModuleDef, error) {
	if daemonRef == "" || len(daemonRef) > 256 || strings.ContainsAny(daemonRef, "/\x00\r\n") || cli == nil {
		return nil, errors.New("Docker module requires a host-selected daemon reference and client")
	}
	return moduleDefinition(daemonRef, cli), nil
}

// A nil client registers the same typed API in an unconfigured host without
// introducing implicit daemon discovery or authority.
func moduleDefinition(daemonRef string, cli *client.Client) *luaapi.ModuleDef {
	return &luaapi.ModuleDef{
		Name: "docker_pty", Description: "Authorized attachment to an existing Docker PTY",
		Class: []string{luaapi.ClassIO, luaapi.ClassProcess, luaapi.ClassNondeterministic},
		Types: ModuleTypes,
		Build: func() (*lua.LTable, []luaapi.YieldType) {
			module := lua.CreateTable(0, 1)
			module.RawSetString("attach", lua.LGoFunc(func(l *lua.LState) int {
				expected, err := decodeIdentity(l.Get(1))
				if err != nil {
					return moduleError(l, err.Error())
				}
				if cli == nil {
					return moduleError(l, "Docker is not configured by the host")
				}
				ctx := l.Context()
				if ctx == nil {
					return moduleError(l, "Docker attachment requires an authenticated scope")
				}
				if actor, ok := secapi.GetActor(ctx); !ok || actor.ID == "" {
					return moduleError(l, "Docker attachment requires an authenticated actor")
				}
				if _, ok := secapi.GetScope(ctx); !ok {
					return moduleError(l, "Docker attachment requires an authenticated scope")
				}
				metadata := attrs.Bag{"image_id": expected.ImageID, "started_at": expected.StartedAt, "labels": expected.Labels}
				if !security.IsAllowed(ctx, "docker.attach", daemonRef+"/"+expected.ContainerID, metadata) {
					return moduleError(l, "permission denied: attach Docker container")
				}
				process, err := New(ctx, cli, expected)
				if err != nil {
					return moduleError(l, err.Error())
				}
				value.PushTypedUserData(l, luaexec.NewProcess(ctx, process), "exec.Process")
				l.Push(lua.LNil)
				return 2
			}))
			module.Immutable = true
			return module, nil
		},
	}
}

func moduleError(l *lua.LState, message string) int {
	l.Push(lua.LNil)
	l.Push(lua.NewLuaError(l, message).WithKind(lua.Invalid).WithRetryable(false))
	return 2
}
func decodeIdentity(raw lua.LValue) (Identity, error) {
	object, ok := raw.(*lua.LTable)
	if !ok {
		return Identity{}, errors.New("Docker identity must be an object")
	}
	expected := Identity{Labels: map[string]string{}}
	var invalid bool
	object.ForEach(func(key, val lua.LValue) {
		name, keyOK := key.(lua.LString)
		if !keyOK {
			invalid = true
			return
		}
		switch string(name) {
		case "container_id":
			text, ok := val.(lua.LString)
			if !ok {
				invalid = true
			}
			expected.ContainerID = string(text)
		case "image_id":
			text, ok := val.(lua.LString)
			if !ok {
				invalid = true
			}
			expected.ImageID = string(text)
		case "started_at":
			text, ok := val.(lua.LString)
			if !ok {
				invalid = true
			}
			expected.StartedAt = string(text)
		case "labels":
			labels, ok := val.(*lua.LTable)
			if !ok {
				invalid = true
				return
			}
			labels.ForEach(func(k, v lua.LValue) {
				name, okName := k.(lua.LString)
				text, okText := v.(lua.LString)
				if !okName || !okText || len(expected.Labels) >= 32 || len(name) == 0 || len(name) > 256 || len(text) == 0 || len(text) > 4096 {
					invalid = true
					return
				}
				expected.Labels[string(name)] = string(text)
			})
		default:
			invalid = true
		}
	})
	if invalid || !hexID(expected.ContainerID) || len(expected.ImageID) != 71 || len(expected.StartedAt) == 0 || len(expected.StartedAt) > 64 || len(expected.Labels) == 0 {
		return Identity{}, errors.New("invalid Docker attachment identity")
	}
	return expected, nil
}
