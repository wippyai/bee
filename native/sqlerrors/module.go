// SPDX-License-Identifier: MIT

// Package sqlerrors formats native SQL error evidence at Bee's Lua boundary.
package sqlerrors

import (
	"context"
	"errors"

	"fmt"
	"github.com/mattn/go-sqlite3"

	lua "github.com/wippyai/go-lua"
	"github.com/wippyai/go-lua/types/io"
	"github.com/wippyai/go-lua/types/typ"
	"github.com/wippyai/runtime/api/boot"
	luaapi "github.com/wippyai/runtime/api/runtime/lua"
	luaboot "github.com/wippyai/runtime/boot/components/runtime/lua"
)

var Module = &luaapi.ModuleDef{
	Name: "sqlerrors", Description: "Native SQL error messages and SQLite result codes",
	Build: buildModule, Types: moduleTypes,
}

func Component() boot.Component {
	return boot.New(boot.P{Name: "bee.sqlerrors", DependsOn: []boot.Name{luaboot.EngineName},
		Load: func(ctx context.Context) (context.Context, error) {
			code := luaboot.GetCodeManager(ctx)
			if code == nil {
				return ctx, fmt.Errorf("SQL error formatting requires Lua")
			}
			return ctx, luaboot.AddModules(ctx, code, Module)
		}})
}

func moduleTypes() *io.Manifest {
	manifest := io.NewManifest("sqlerrors")
	manifest.SetExport(typ.NewInterface("sqlerrors", []typ.Method{
		{Name: "describe", Type: typ.Func().Param("error", typ.Unknown).Returns(typ.String).Build()},
	}))
	return manifest
}

func buildModule() (*lua.LTable, []luaapi.YieldType) {
	module := lua.CreateTable(0, 1)
	module.RawSetString("describe", lua.LGoFunc(describe))
	module.Immutable = true
	return module, nil
}

func describe(l *lua.LState) int {
	l.Push(lua.LString(describeValue(l.Get(1))))
	return 1
}

func describeValue(value lua.LValue) string {
	message := value.String()
	err, ok := value.(error)
	if !ok {
		return message
	}
	var native sqlite3.Error
	if errors.As(err, &native) {
		return fmt.Sprintf("%s (SQLite code %d, extended %d)", message, native.Code, native.ExtendedCode)
	}
	return message
}
