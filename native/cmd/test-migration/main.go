package main

import (
	"encoding/json"
	"fmt"
	"os"

	lua "github.com/wippyai/go-lua"
)

func fromJSON(state *lua.LState, value any) lua.LValue {
	switch value := value.(type) {
	case nil:
		return lua.LNil
	case bool:
		return lua.LBool(value)
	case float64:
		return lua.LNumber(value)
	case string:
		return lua.LString(value)
	case []any:
		table := state.NewTable()
		for _, item := range value {
			table.Append(fromJSON(state, item))
		}
		return table
	case map[string]any:
		table := state.NewTable()
		for key, item := range value {
			table.RawSetString(key, fromJSON(state, item))
		}
		return table
	default:
		panic(fmt.Sprintf("unsupported JSON value: %T", value))
	}
}

func toJSON(value lua.LValue) any {
	switch value := value.(type) {
	case *lua.LNilType:
		return nil
	case lua.LBool:
		return bool(value)
	case lua.LNumber:
		return float64(value)
	case lua.LString:
		return string(value)
	case *lua.LTable:
		if value.Len() > 0 {
			items := make([]any, value.Len())
			for i := range items {
				items[i] = toJSON(value.RawGetInt(i + 1))
			}
			return items
		}
		items := map[string]any{}
		value.ForEach(func(key, item lua.LValue) { items[key.String()] = toJSON(item) })
		return items
	default:
		panic(fmt.Sprintf("unsupported Lua value: %T", value))
	}
}

func run(path string) error {
	state := lua.NewState()
	defer state.Close()
	input, output := json.NewDecoder(os.Stdin), json.NewEncoder(os.Stdout)
	state.SetGlobal("rpc", state.NewFunction(func(state *lua.LState) int {
		args := make([]any, state.GetTop()-1)
		for i := range args {
			args[i] = toJSON(state.Get(i + 2))
		}
		if err := output.Encode(map[string]any{"method": state.CheckString(1), "args": args}); err != nil {
			state.RaiseError("%s", err)
			return 0
		}
		var result any
		if err := input.Decode(&result); err != nil {
			state.RaiseError("%s", err)
			return 0
		}
		state.Push(fromJSON(state, result))
		return 1
	}))
	if err := state.DoString(`
local db = {
    query = function(_, sql, args) return rpc("query", sql, args) end,
    execute = function(_, sql, args) return rpc("execute", sql, args) end,
}
local modules = {
    json = {decode = function(value) return rpc("decode", value) end},
    canonical = {
        encode = function(value) return rpc("encode", value) end,
        digest = function(value) return rpc("digest", value) end,
    },
    hash = {sha256 = function(value) return rpc("sha256", value) end},
    migration = {define = function(body) return body end},
}
function migration(_, body) body() end
function database(_, body) body() end
function up(body) body(db) end
function require(name) return assert(modules[name], name) end
`); err != nil {
		return err
	}
	if err := state.DoFile(path); err != nil {
		return err
	}
	return state.CallByParam(lua.P{Fn: state.Get(-1), NRet: 0, Protect: true})
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: test-migration <source.lua>")
		os.Exit(2)
	}
	if err := run(os.Args[1]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
