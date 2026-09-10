// SPDX-License-Identifier: MIT

package owner

import (
	"context"
	"fmt"
	"sync/atomic"

	lua "github.com/wippyai/go-lua"
	"github.com/wippyai/runtime/api/dispatcher"
	"github.com/wippyai/runtime/api/payload"
	"github.com/wippyai/runtime/api/pid"
	runtimeapi "github.com/wippyai/runtime/api/runtime"
	luaapi "github.com/wippyai/runtime/api/runtime/lua"
	ttyapi "github.com/wippyai/runtime/api/tty"
	"github.com/wippyai/runtime/runtime/lua/engine"
	"github.com/wippyai/runtime/runtime/lua/engine/value"
)

// Command ID 0xbee1 for localdisplay (0xbee0 is ioevents).
const acceptCommand dispatcher.CommandID = 0xbee1

var sequence atomic.Uint64

func init() {
	dispatcher.MustRegisterCommands("bee.localdisplay", acceptCommand)
	value.RegisterTypeMethods(nil, attachmentTypeName, nil, map[string]lua.LGoFunc{
		"grant":   attachmentGrant,
		"channel": attachmentChannel,
		"close":   attachmentClose,
	})
}

// Module exposes the localdisplay Lua API.
var Module = &luaapi.ModuleDef{
	Name:        "localdisplay",
	Description: "Process-owned local display attachments",
	Class:       []string{luaapi.ClassIO, luaapi.ClassNondeterministic},
	Build:       buildModule,
	Types:       ModuleTypes,
}

func buildModule() (*lua.LTable, []luaapi.YieldType) {
	module := lua.CreateTable(0, 1)
	module.RawSetString("accept", lua.LGoFunc(acceptDisplay))
	module.Immutable = true
	return module, []luaapi.YieldType{{Sample: &acceptYield{}, CmdID: acceptCommand}}
}

type attachmentHandle struct {
	owner      pid.PID
	epoch      uint64
	grant      string
	channel    *engine.Channel
	userdata   *lua.LUserData
	attachment *Attachment
}

func checkCallerOwner(l *lua.LState, handle *attachmentHandle) bool {
	callerPID, ok := runtimeapi.GetFramePID(l.Context())
	if !ok || callerPID != handle.owner {
		return false
	}
	process := engine.GetProcess(l)
	if process != nil && process.Epoch() != handle.epoch {
		return false
	}
	return true
}

func attachmentGrant(l *lua.LState) int {
	handle, ok := l.CheckUserData(1).Value.(*attachmentHandle)
	if !ok {
		l.ArgError(1, "localdisplay attachment expected")
		return 0
	}
	if !checkCallerOwner(l, handle) {
		l.ArgError(1, "attachment cannot be used from another caller frame")
		return 0
	}
	l.Push(lua.LString(handle.grant))
	return 1
}

func attachmentChannel(l *lua.LState) int {
	handle, ok := l.CheckUserData(1).Value.(*attachmentHandle)
	if !ok {
		l.ArgError(1, "localdisplay attachment expected")
		return 0
	}
	if !checkCallerOwner(l, handle) {
		l.ArgError(1, "attachment cannot be used from another caller frame")
		return 0
	}
	l.Push(handle.userdata)
	return 1
}

func attachmentClose(l *lua.LState) int {
	handle, ok := l.CheckUserData(1).Value.(*attachmentHandle)
	if !ok {
		l.ArgError(1, "localdisplay attachment expected")
		return 0
	}
	if !checkCallerOwner(l, handle) {
		l.ArgError(1, "attachment cannot be used from another caller frame")
		return 0
	}
	closed := handle.attachment.Close()
	if process := engine.GetProcess(l); process != nil {
		process.UnsubscribeChannel(handle.channel)
	}
	l.Push(lua.LBool(closed))
	return 1
}

func acceptDisplay(l *lua.LState) int {
	width := l.CheckInt(1)
	height := l.CheckInt(2)
	if err := ttyapi.ValidateViewportSize(width, height); err != nil {
		l.Push(lua.LNil)
		l.Push(lua.NewLuaError(l, "invalid viewport dimensions").WithKind(lua.Invalid))
		return 2
	}

	process := engine.GetProcess(l)
	owner, ok := runtimeapi.GetFramePID(l.Context())
	if process == nil || !ok {
		l.Push(lua.LNil)
		l.Push(lua.NewLuaError(l, "localdisplay accept requires a process frame").WithKind(lua.Invalid))
		return 2
	}

	topic := fmt.Sprintf("localdisplay@%d", sequence.Add(1))
	channel, id, generation, err := process.SubscribeRouted(topic, closedBuffer)
	if err != nil {
		l.Push(lua.LNil)
		l.Push(lua.WrapErrorWithLua(l, err, "subscribe"))
		return 2
	}
	process.SetTopicHandler(topic, decodeClosed)

	acceptContext, cancel := context.WithCancel(l.Context())
	process.SetSubscriptionCleanup(channel, cancel)

	operation := &acceptYield{
		channel: channel,
		cancel:  cancel,
		command: acceptCommandPayload{
			context:      acceptContext,
			frameContext: l.Context(),
			width:        width,
			height:       height,
			owner:        owner,
			topic:        topic,
			epoch:        process.Epoch(),
			id:           id,
			generation:   generation,
		},
	}
	l.Push(operation)
	return -1
}

type acceptCommandPayload struct {
	context      context.Context
	frameContext context.Context
	width        int
	height       int
	owner        pid.PID
	topic        string
	epoch        uint64
	id           uint64
	generation   *atomic.Uint64
}

func (*acceptCommandPayload) CmdID() dispatcher.CommandID { return acceptCommand }

type acceptYield struct {
	command acceptCommandPayload
	channel *engine.Channel
	cancel  context.CancelFunc
}

func (*acceptYield) String() string                      { return "<localdisplay.accept>" }
func (*acceptYield) Type() lua.LValueType                { return lua.LTUserData }
func (*acceptYield) CmdID() dispatcher.CommandID         { return acceptCommand }
func (yield *acceptYield) ToCommand() dispatcher.Command { cmd := yield.command; return &cmd }
func (*acceptYield) Release()                            {}

func (yield *acceptYield) HandleResult(l *lua.LState, data any, err error) []lua.LValue {
	process := engine.GetProcess(l)
	if err != nil {
		yield.cancel()
		if process != nil {
			process.UnsubscribeChannel(yield.channel)
		}
		return []lua.LValue{lua.LNil, lua.WrapErrorWithLua(l, err, "accept local display")}
	}

	attachment, ok := data.(*Attachment)
	if !ok || process == nil {
		yield.cancel()
		if attachment != nil {
			attachment.Close()
		}
		return []lua.LValue{lua.LNil, lua.NewLuaError(l, "invalid accept completion").WithKind(lua.Internal)}
	}

	// Dual-independent cleanup: update subscription cleanup with attachment close
	if !process.SetSubscriptionCleanup(yield.channel, func() {
		yield.cancel()
		attachment.Close()
	}) {
		attachment.Close()
		return []lua.LValue{lua.LNil, lua.NewLuaError(l, "process subscription defunct").WithKind(lua.Canceled)}
	}

	channelUD := engine.PushChannel(l, yield.channel)
	l.Pop(1)
	handle := value.PushTypedUserData(l, &attachmentHandle{
		owner:      yield.command.owner,
		epoch:      yield.command.epoch,
		grant:      attachment.Grant(),
		channel:    yield.channel,
		userdata:   channelUD,
		attachment: attachment,
	}, attachmentTypeName)
	l.Pop(1)
	return []lua.LValue{handle, lua.LNil}
}

func decodeClosed(_ context.Context, l *lua.LState, _ pid.PID, _ string, items []payload.Payload) lua.LValue {
	if len(items) != 1 {
		return lua.LNil
	}
	closed, ok := items[0].Data().(Closed)
	if !ok {
		return lua.LNil
	}
	record := l.CreateTable(0, 2)
	record.RawSetString("kind", lua.LString("closed"))
	record.RawSetString("error_code", lua.LString(closed.ErrorCode))
	return record
}
