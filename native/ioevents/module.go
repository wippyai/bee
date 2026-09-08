// SPDX-License-Identifier: MIT

package ioevents

import (
	"context"
	"fmt"
	"sync/atomic"

	lua "github.com/wippyai/go-lua"
	"github.com/wippyai/runtime/api/dispatcher"
	apierror "github.com/wippyai/runtime/api/error"
	fsapi "github.com/wippyai/runtime/api/fs"
	"github.com/wippyai/runtime/api/payload"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/api/relay"
	runtimeapi "github.com/wippyai/runtime/api/runtime"
	luaapi "github.com/wippyai/runtime/api/runtime/lua"
	"github.com/wippyai/runtime/runtime/lua/engine"
	"github.com/wippyai/runtime/runtime/lua/engine/value"
	"github.com/wippyai/runtime/runtime/security"
)

const watchCommand dispatcher.CommandID = 0xbee0
const watchType = "ioevents.Watch"

var sequence atomic.Uint64

func init() {
	dispatcher.MustRegisterCommands("bee.ioevents", watchCommand)
	value.RegisterTypeMethods(nil, watchType, nil, map[string]lua.LGoFunc{"channel": watchChannel, "close": watchClose})
}

var Module = &luaapi.ModuleDef{
	Name: "ioevents", Description: "Process-owned filesystem change hints",
	Class: []string{luaapi.ClassIO, luaapi.ClassNondeterministic},
	Build: buildModule, Types: ModuleTypes,
}

func buildModule() (*lua.LTable, []luaapi.YieldType) {
	module := lua.CreateTable(0, 1)
	module.RawSetString("watch", lua.LGoFunc(watchDirectory))
	module.Immutable = true
	return module, []luaapi.YieldType{{Sample: &watchYield{}, CmdID: watchCommand}}
}

type watchHandle struct {
	channel  *engine.Channel
	userdata *lua.LUserData
}

func watchChannel(l *lua.LState) int {
	handle, ok := l.CheckUserData(1).Value.(*watchHandle)
	if !ok {
		l.ArgError(1, "ioevents watch expected")
		return 0
	}
	l.Push(handle.userdata)
	return 1
}

func watchClose(l *lua.LState) int {
	handle, ok := l.CheckUserData(1).Value.(*watchHandle)
	if !ok {
		l.ArgError(1, "ioevents watch expected")
		return 0
	}
	if process := engine.GetProcess(l); process != nil {
		process.UnsubscribeChannel(handle.channel)
	}
	l.Push(lua.LTrue)
	return 1
}

func watchDirectory(l *lua.LState) int {
	resourceName := l.CheckString(1)
	relative := l.OptString(2, ".")
	if resourceName == "" || len(resourceName) > 256 || len(relative) > 4096 {
		l.Push(lua.LNil)
		l.Push(lua.NewLuaError(l, "invalid filesystem resource or watch path").WithKind(lua.Invalid))
		return 2
	}
	process := engine.GetProcess(l)
	owner, ok := runtimeapi.GetFramePID(l.Context())
	if process == nil || !ok {
		l.Push(lua.LNil)
		l.Push(lua.NewLuaError(l, "filesystem watches require a process").WithKind(lua.Invalid))
		return 2
	}
	topic := fmt.Sprintf("ioevents@%d", sequence.Add(1))
	channel, id, generation, err := process.SubscribeRouted(topic, eventBuffer)
	if err != nil {
		l.Push(lua.LNil)
		l.Push(lua.WrapErrorWithLua(l, err, "subscribe"))
		return 2
	}
	process.SetTopicHandler(topic, decodeEvent)
	watchContext, cancel := context.WithCancel(l.Context())
	process.SetSubscriptionCleanup(channel, cancel)
	operation := &watchYield{channel: channel, cancel: cancel, command: startCommand{
		context: watchContext, resource: resourceName, relative: relative, owner: owner,
		topic: topic, epoch: process.Epoch(), id: id, generation: generation,
	}}
	l.Push(operation)
	return -1
}

type startCommand struct {
	context                   context.Context
	resource, relative, topic string
	owner                     pid.PID
	epoch, id                 uint64
	generation                *atomic.Uint64
}

func (*startCommand) CmdID() dispatcher.CommandID { return watchCommand }

type watchYield struct {
	command startCommand
	channel *engine.Channel
	cancel  context.CancelFunc
}

func (*watchYield) String() string                      { return "<ioevents.watch>" }
func (*watchYield) Type() lua.LValueType                { return lua.LTUserData }
func (*watchYield) CmdID() dispatcher.CommandID         { return watchCommand }
func (yield *watchYield) ToCommand() dispatcher.Command { command := yield.command; return &command }
func (*watchYield) Release()                            {}
func (yield *watchYield) HandleResult(l *lua.LState, data any, err error) []lua.LValue {
	process := engine.GetProcess(l)
	if err != nil {
		yield.cancel()
		if process != nil {
			process.UnsubscribeChannel(yield.channel)
		}
		return []lua.LValue{lua.LNil, lua.WrapErrorWithLua(l, err, "watch directory")}
	}
	watch, ok := data.(*Watch)
	if !ok || process == nil {
		yield.cancel()
		if watch != nil {
			watch.Close()
		}
		return []lua.LValue{lua.LNil, lua.NewLuaError(l, "invalid watch completion").WithKind(lua.Internal)}
	}
	if !process.SetSubscriptionCleanup(yield.channel, func() { yield.cancel(); watch.Close() }) {
		watch.Close()
	}
	channelUD := engine.PushChannel(l, yield.channel)
	l.Pop(1)
	handle := value.PushTypedUserData(l, &watchHandle{channel: yield.channel, userdata: channelUD}, watchType)
	l.Pop(1)
	return []lua.LValue{handle, lua.LNil}
}

func decodeEvent(_ context.Context, l *lua.LState, _ pid.PID, _ string, items []payload.Payload) lua.LValue {
	if len(items) != 1 {
		return lua.LNil
	}
	event, ok := items[0].Data().(Event)
	if !ok {
		return lua.LNil
	}
	record := l.CreateTable(0, 4)
	record.RawSetString("kind", lua.LString(event.Kind))
	record.RawSetString("resource", lua.LString(event.Resource))
	record.RawSetString("path", lua.LString(event.Path))
	record.RawSetString("operation", lua.LString(event.Operation))
	return record
}

func (manager *Manager) Handle(ctx context.Context, command dispatcher.Command, tag uint64, receiver dispatcher.ResultReceiver) error {
	request, ok := command.(*startCommand)
	if !ok {
		return fmt.Errorf("unexpected I/O events command")
	}
	if !security.IsAllowed(ctx, "ioevents.watch", request.resource, nil) || !security.IsAllowed(ctx, "fs.get", request.resource, nil) {
		receiver.CompleteYield(tag, nil, apierror.New(apierror.PermissionDenied, "filesystem watch is not permitted").WithRetryable(apierror.False))
		return nil
	}
	registry := fsapi.GetRegistry(ctx)
	if registry == nil {
		receiver.CompleteYield(tag, nil, fmt.Errorf("filesystem registry unavailable"))
		return nil
	}
	filesystem, ok := registry.GetFS(request.resource)
	if !ok {
		receiver.CompleteYield(tag, nil, apierror.New(apierror.NotFound, "filesystem resource not found"))
		return nil
	}
	host, ok := filesystem.(fsapi.HostPathFS)
	if !ok {
		receiver.CompleteYield(tag, nil, apierror.New(apierror.Invalid, "filesystem provider does not support native watches"))
		return nil
	}
	node := relay.GetNode(ctx)
	if node == nil {
		receiver.CompleteYield(tag, nil, fmt.Errorf("process relay unavailable"))
		return nil
	}
	root := host.RootPath()
	go func() {
		watch, err := manager.Start(request.context, fmt.Sprintf("%s/%d", request.owner.String(), request.epoch), request.resource, root, request.relative, func(event Event) error {
			frame := &engine.SubscriptionFrame{Epoch: request.epoch, SubID: request.id, Gen: request.generation.Load(), Payloads: payload.Payloads{payload.NewPayload(event, payload.Golang)}}
			message := relay.NewPackage(pid.PID{}, request.owner, request.topic, engine.NewSubscriptionFramePayload(frame))
			for _, item := range message.Messages {
				item.MaxItems = eventBuffer
				item.MaxBytes = 1024 * 1024
				item.PayloadBytes = int64(len(event.Path) + len(event.Resource) + len(event.Operation) + 64)
			}
			return node.Send(message)
		})
		receiver.CompleteYield(tag, watch, err)
	}()
	return nil
}
