// SPDX-License-Identifier: MIT

package ioevents

import (
	"context"
	"fmt"
	"path/filepath"
	"sync/atomic"

	lua "github.com/wippyai/go-lua"
	"github.com/wippyai/runtime/api/attrs"
	"github.com/wippyai/runtime/api/dispatcher"
	apierror "github.com/wippyai/runtime/api/error"
	fsapi "github.com/wippyai/runtime/api/fs"
	"github.com/wippyai/runtime/api/payload"
	"github.com/wippyai/runtime/api/pid"
	registryapi "github.com/wippyai/runtime/api/registry"
	"github.com/wippyai/runtime/api/relay"
	runtimeapi "github.com/wippyai/runtime/api/runtime"
	luaapi "github.com/wippyai/runtime/api/runtime/lua"
	"github.com/wippyai/runtime/runtime/lua/engine"
	"github.com/wippyai/runtime/runtime/lua/engine/value"
	fsmod "github.com/wippyai/runtime/runtime/lua/modules/fs"
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
	fail := func(kind lua.Kind, message string) int {
		l.Push(lua.LNil)
		l.Push(lua.NewLuaError(l, message).WithKind(kind).WithRetryable(false))
		return 2
	}
	handle, _ := l.Get(1).(*lua.LUserData)
	var files *fsmod.FS
	if handle != nil {
		files, _ = handle.Value.(*fsmod.FS)
	}
	if files == nil {
		return fail(lua.Invalid, "watch expects a filesystem from fs.get")
	}
	path := l.OptString(2, ".")
	if len(path) > 4096 {
		return fail(lua.Invalid, "watch path is too long")
	}
	relative, err := files.Resolve(path)
	if err != nil {
		return fail(lua.Invalid, "watch requires a contained relative path")
	}
	recursive, invalid := watchOptions(l.Get(3))
	if invalid != "" {
		return fail(lua.Invalid, invalid)
	}
	// The caller's frame context carries its actor and policy scope and the
	// registries its fs handle came from; the dispatcher context the command
	// handler runs under carries none of them.
	ctx := l.Context()
	resource, root, err := watchSource(ctx, files.Backend())
	if err != nil {
		l.Push(lua.LNil)
		l.Push(lua.WrapErrorWithLua(l, err, "watch directory"))
		return 2
	}
	if !security.IsAllowed(ctx, "ioevents.watch", resource, nil) {
		return fail(lua.PermissionDenied, "filesystem watch is not permitted: "+resource)
	}
	process := engine.GetProcess(l)
	owner, ok := runtimeapi.GetFramePID(ctx)
	if process == nil || !ok {
		return fail(lua.Invalid, "filesystem watches require a process")
	}
	topic := fmt.Sprintf("ioevents@%d", sequence.Add(1))
	channel, id, generation, err := process.SubscribeRouted(topic, eventBuffer)
	if err != nil {
		l.Push(lua.LNil)
		l.Push(lua.WrapErrorWithLua(l, err, "subscribe"))
		return 2
	}
	process.SetTopicHandler(topic, delivery(channel, Event{Kind: EventRescan, Resource: resource, Path: relative}))
	watchContext, cancel := context.WithCancel(ctx)
	process.SetSubscriptionCleanup(channel, cancel)
	operation := &watchYield{channel: channel, cancel: cancel, command: startCommand{
		context: watchContext, resource: resource, root: root, relative: filepath.FromSlash(relative), recursive: recursive,
		owner: owner, topic: topic, epoch: process.Epoch(), id: id, generation: generation,
	}}
	l.Push(operation)
	return -1
}

// watchSource names the registry volume an fs handle came from and the host
// directory behind it. The handle's backend is the instance the filesystem
// registry holds for exactly one fs.directory entry. A host-backed volume is
// watched at its root; a read-only volume withholds its host directory, so
// the one host-backed fs.directory whose meta.watch_for names the volume
// serves its watches, and the caller never acquires it.
func watchSource(ctx context.Context, backend fsapi.FS) (string, string, error) {
	filesystems, finder := fsapi.GetRegistry(ctx), registryapi.GetFinder(ctx)
	if filesystems == nil || finder == nil {
		return "", "", apierror.New(apierror.Internal, "filesystem registry unavailable")
	}
	volumes, err := finder.Find(attrs.Bag{".kind": "fs.directory"})
	if err != nil {
		return "", "", apierror.New(apierror.Unavailable, "registry cannot be read").WithRetryable(apierror.True)
	}
	resource := ""
	for _, volume := range volumes {
		if filesystem, ok := filesystems.GetFS(volume.ID.String()); ok && filesystem == backend {
			resource = volume.ID.String()
			break
		}
	}
	unwatchable := apierror.New(apierror.Invalid, "filesystem is not a watchable volume").WithRetryable(apierror.False)
	if resource == "" {
		return "", "", unwatchable
	}
	if host, ok := backend.(fsapi.HostPathFS); ok {
		return resource, host.RootPath(), nil
	}
	sources, err := finder.Find(attrs.Bag{".kind": "fs.directory", "meta.watch_for": resource})
	if err != nil {
		return "", "", apierror.New(apierror.Unavailable, "registry cannot be read").WithRetryable(apierror.True)
	}
	if len(sources) != 1 {
		return "", "", unwatchable
	}
	source, ok := filesystems.GetFS(sources[0].ID.String())
	host, hosted := source.(fsapi.HostPathFS)
	if !ok || !hosted {
		return "", "", unwatchable
	}
	return resource, host.RootPath(), nil
}

type startCommand struct {
	context                         context.Context
	resource, root, relative, topic string
	recursive                       bool
	owner                           pid.PID
	epoch, id                       uint64
	generation                      *atomic.Uint64
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

// watchOptions reads the optional {recursive = boolean} table.
func watchOptions(raw lua.LValue) (bool, string) {
	if raw == lua.LNil {
		return false, ""
	}
	options, ok := raw.(*lua.LTable)
	if !ok {
		return false, "watch options must be a table"
	}
	recursive, invalid := false, ""
	options.ForEach(func(key, value lua.LValue) {
		switch {
		case key.String() == "recursive" && value.Type() == lua.LTBool:
			recursive = value == lua.LTrue
		case key.String() == "recursive":
			invalid = "watch option recursive must be a boolean"
		case invalid == "":
			invalid = "unknown watch option: " + key.String()
		}
	})
	return recursive, invalid
}

// delivery builds the topic handler that turns native events into Lua
// records. The runtime drops a routed frame that finds the channel full, so
// the last free slot carries a rescan of the watched directory instead, and
// notices are dropped until the consumer has received it: the listing the
// consumer makes on that rescan covers them.
func delivery(channel *engine.Channel, rescan Event) engine.TopicHandler {
	behind := false
	return func(_ context.Context, l *lua.LState, _ pid.PID, _ string, items []payload.Payload) lua.LValue {
		if len(items) != 1 {
			return nil
		}
		event, ok := items[0].Data().(Event)
		if !ok {
			return nil
		}
		if behind {
			if channel.Size() > 0 {
				return nil
			}
			behind = false
		}
		if channel.Slots() <= 1 {
			behind = true
			event = rescan
		}
		return eventRecord(l, event)
	}
}

func eventRecord(l *lua.LState, event Event) lua.LValue {
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
	node := relay.GetNode(ctx)
	if node == nil {
		receiver.CompleteYield(tag, nil, apierror.New(apierror.Internal, "process relay unavailable"))
		return nil
	}
	send := func(item payload.Payload, size int) error {
		frame := &engine.SubscriptionFrame{Epoch: request.epoch, SubID: request.id, Gen: request.generation.Load(), Payloads: payload.Payloads{item}}
		message := relay.NewPackage(pid.PID{}, request.owner, request.topic, engine.NewSubscriptionFramePayload(frame))
		for _, queued := range message.Messages {
			queued.MaxItems = eventBuffer
			queued.MaxBytes = 1024 * 1024
			queued.PayloadBytes = int64(size)
		}
		return node.Send(message)
	}
	go func() {
		watch, err := manager.Start(request.context, fmt.Sprintf("%s/%d", request.owner.String(), request.epoch), request.resource, request.root, request.relative, request.recursive, func(event Event) error {
			return send(payload.NewPayload(event, payload.Golang), len(event.Path)+len(event.Resource)+len(event.Operation)+64)
		})
		receiver.CompleteYield(tag, watch, err)
		if watch == nil {
			return
		}
		// The channel closes when the native watch ends, whichever side ends it.
		<-watch.Done()
		// An exited owner has no channel left to close.
		_ = send(payload.NewTerminal(), 0)
	}()
	return nil
}
