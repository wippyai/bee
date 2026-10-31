// SPDX-License-Identifier: MIT

package host

import (
	"errors"
	"strconv"

	lua "github.com/wippyai/go-lua"
	"github.com/wippyai/go-lua/types/io"
	"github.com/wippyai/go-lua/types/typ"
	luaapi "github.com/wippyai/runtime/api/runtime/lua"
	"github.com/wippyai/runtime/runtime/security"
)

// ObserveGroupAction is the permission to ask whether a process group still
// has members; the resource is the decimal process group id.
const ObserveGroupAction = "hostprocess.observe_group"

// errGroupUnsupported reports a platform without process groups.
var errGroupUnsupported = errors.New("process groups are not supported on this platform")

// ProcessModule lets a component prove that a process group it recorded has
// no members left. A group id stays allocated while any process belongs to
// the group, so an empty group can never be refilled under the same id by the
// recorded tree. A present group proves nothing about which processes are in
// it.
var ProcessModule = &luaapi.ModuleDef{
	Name: "hostprocess", Description: "Membership of recorded host process groups",
	Class: []string{luaapi.ClassIO, luaapi.ClassNondeterministic},
	Build: buildProcessModule, Types: processModuleTypes,
}

func buildProcessModule() (*lua.LTable, []luaapi.YieldType) {
	module := lua.CreateTable(0, 1)
	module.RawSetString("group_present", lua.LGoFunc(groupPresent))
	module.Immutable = true
	return module, nil
}

// groupPresent(pgid) returns true while the group has a member, false once
// it has none, or nil and an error when membership cannot be observed.
func groupPresent(l *lua.LState) int {
	pgid := l.CheckInt(1)
	if pgid < 2 {
		l.Push(lua.LNil)
		l.Push(lua.NewLuaError(l, "process group id must be at least 2").WithKind(lua.Invalid))
		return 2
	}
	if !security.IsAllowed(l.Context(), ObserveGroupAction, strconv.Itoa(pgid), nil) {
		l.Push(lua.LNil)
		l.Push(lua.NewLuaError(l, "process group observation is not permitted").WithKind(lua.PermissionDenied).WithRetryable(false))
		return 2
	}
	present, err := processGroupPresent(pgid)
	if err != nil {
		l.Push(lua.LNil)
		l.Push(lua.WrapErrorWithLua(l, err, "observe process group"))
		return 2
	}
	l.Push(lua.LBool(present))
	return 1
}

func processModuleTypes() *io.Manifest {
	manifest := io.NewManifest("hostprocess")
	manifest.SetExport(typ.NewInterface("hostprocess", []typ.Method{
		{Name: "group_present", Type: typ.Func().Param("pgid", typ.Integer).Returns(typ.NewOptional(typ.Boolean), typ.NewOptional(typ.LuaError)).Build()},
	}))
	return manifest
}
