// SPDX-License-Identifier: MIT

package ioevents

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	lua "github.com/wippyai/go-lua"
	"github.com/wippyai/runtime/api/attrs"
	ctxapi "github.com/wippyai/runtime/api/context"
	fsapi "github.com/wippyai/runtime/api/fs"
	"github.com/wippyai/runtime/api/payload"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/api/process"
	"github.com/wippyai/runtime/api/relay"
	runtimeapi "github.com/wippyai/runtime/api/runtime"
	secapi "github.com/wippyai/runtime/api/security"
	"github.com/wippyai/runtime/runtime/lua/engine"
)

type watchTestScope struct {
	secapi.Scope
	denied string
}

func (s watchTestScope) Evaluate(actor secapi.Actor, action, resource string, _ attrs.Bag) secapi.Result {
	if actor.ID != "watch-owner" || resource != "workspace" || action == s.denied {
		return secapi.Deny
	}
	return secapi.Allow
}

type watchTestFS struct {
	fsapi.FS
	root string
}

func (f watchTestFS) RootPath() string { return f.root }

type watchTestRegistry struct{ fs fsapi.FS }

func (r watchTestRegistry) GetFS(name string) (fsapi.FS, bool) { return r.fs, name == "workspace" }

type watchTestNode struct {
	relay.Node
	events chan process.Event
}

func (n watchTestNode) Send(p *relay.Package) error {
	n.events <- process.Event{Type: process.EventMessage, Data: p}
	return nil
}

type watchTestReceiver struct{ events chan process.Event }

func (r watchTestReceiver) CompleteYield(tag uint64, data any, err error) {
	r.events <- process.Event{Type: process.EventYieldComplete, Tag: tag, Data: data, Error: err}
}

func watchTestProcess(t *testing.T, script, denied string) *engine.Process {
	t.Helper()
	ctx, _ := ctxapi.OpenFrameContext(ctxapi.NewRootContext())
	if err := secapi.SetActor(ctx, secapi.Actor{ID: "watch-owner"}); err != nil {
		t.Fatal(err)
	}
	if err := secapi.SetScope(ctx, watchTestScope{denied: denied}); err != nil {
		t.Fatal(err)
	}
	if err := runtimeapi.SetFramePID(ctx, pid.PID{Host: "test", UniqID: "owner"}); err != nil {
		t.Fatal(err)
	}
	p, err := engine.NewProcess(engine.WithScript(script, "watch-test.lua"), engine.WithModuleBinder(func(l *lua.LState) error {
		engine.LoadModuleDef(l, engine.ChannelModule)
		engine.LoadModuleDef(l, Module)
		return nil
	}))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(p.Close)
	if err := p.Init(ctx, "", nil); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestLuaWatchChecksCallerWatchPermissionBeforeYield(t *testing.T) {
	p := watchTestProcess(t, `local w, err = ioevents.watch("workspace"); assert(w == nil and err ~= nil); return true`, "ioevents.watch")
	var out process.StepOutput
	if err := p.Step(nil, &out); err != nil {
		t.Fatal(err)
	}
	if !out.IsDone() || out.Count() != 0 || p.LiveSubscriptionCount() != 0 {
		t.Fatalf("denied watch yielded or leaked: %+v", out)
	}
}

func TestLuaWatchNeedsNoFilesystemAcquisition(t *testing.T) {
	p := watchTestProcess(t, `local w, err = ioevents.watch("workspace"); return true`, "fs.get")
	var out process.StepOutput
	if err := p.Step(nil, &out); err != nil {
		t.Fatal(err)
	}
	if out.Count() != 1 || p.LiveSubscriptionCount() != 1 {
		t.Fatalf("watch without fs.get did not reach the native watcher: %+v", out)
	}
}

func TestLuaWatchNativeDeliveryAndCleanup(t *testing.T) {
	for _, mode := range []string{"close", "exit"} {
		t.Run(mode, func(t *testing.T) {
			script := `local w, err = ioevents.watch("workspace"); assert(w, tostring(err)); local ch = w:channel(); local initial = ch:receive(); assert(initial.kind == "rescan" and initial.resource == "workspace"); while true do local e = ch:receive(); if e.kind == "change" and e.path == "created.txt" then break end end; `
			if mode == "close" {
				script += `assert(w:close()); assert(w:close()); local v, ok = ch:receive(); assert(v == nil and ok == false); `
			}
			script += `return true`
			p := watchTestProcess(t, script, "")
			manager := NewManager()
			t.Cleanup(func() {
				ctx, cancel := context.WithTimeout(context.Background(), time.Second)
				defer cancel()
				if err := manager.Stop(ctx); err != nil {
					t.Error(err)
				}
			})
			root := t.TempDir()
			events := make(chan process.Event, 1024)
			ctx := ctxapi.NewRootContext()
			ctx = fsapi.WithRegistry(ctx, watchTestRegistry{fs: watchTestFS{root: root}})
			ctx = relay.WithNode(ctx, watchTestNode{events: events})
			var out process.StepOutput
			if err := p.Step(nil, &out); err != nil {
				t.Fatal(err)
			}
			if out.Count() != 1 {
				t.Fatalf("expected watcher yield, got %+v", out)
			}
			y := out.Yields()[0]
			if err := manager.Handle(ctx, y.Cmd, y.Tag, watchTestReceiver{events: events}); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(root, "created.txt"), []byte("changed"), 0600); err != nil {
				t.Fatal(err)
			}
			timer := time.NewTimer(3 * time.Second)
			defer timer.Stop()
			created := false
			for !out.IsDone() {
				select {
				case e := <-events:
					if e.Type == process.EventYieldComplete && e.Error == nil && !created {
						created = true
						if err := os.WriteFile(filepath.Join(root, "created.txt"), []byte("native-event"), 0600); err != nil {
							t.Fatal(err)
						}
					}
					out.Reset()
					if err := p.Step([]process.Event{e}, &out); err != nil {
						t.Fatal(err)
					}
				case <-timer.C:
					t.Fatal("watch did not deliver native change through Lua channel")
				}
			}
			if p.LiveSubscriptionCount() != 0 {
				t.Fatal("subscription survived process completion")
			}
			deadline := time.Now().Add(time.Second)
			for {
				manager.mu.Lock()
				live := len(manager.active)
				manager.mu.Unlock()
				if live == 0 {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("native watch survived close/owner exit")
				}
				time.Sleep(time.Millisecond)
			}
		})
	}
}

func TestLuaWatchFailedDispatchReleasesSubscription(t *testing.T) {
	p := watchTestProcess(t, `local w, err = ioevents.watch("workspace"); assert(w == nil and err ~= nil); return true`, "")
	var out process.StepOutput
	if err := p.Step(nil, &out); err != nil {
		t.Fatal(err)
	}
	if out.Count() != 1 || p.LiveSubscriptionCount() != 1 {
		t.Fatalf("watch did not subscribe and yield: %+v", out)
	}
	y := out.Yields()[0]
	events := make(chan process.Event, 1)
	manager := NewManager()
	if err := manager.Handle(ctxapi.NewRootContext(), y.Cmd, y.Tag, watchTestReceiver{events: events}); err != nil {
		t.Fatal(err)
	}
	completion := <-events
	if completion.Error == nil {
		t.Fatal("missing registry should fail dispatch")
	}
	out.Reset()
	if err := p.Step([]process.Event{completion}, &out); err != nil {
		t.Fatal(err)
	}
	if !out.IsDone() || p.LiveSubscriptionCount() != 0 {
		t.Fatal("failed dispatch leaked subscription")
	}
}

// driveWatch runs script, serving its watch yields from a manager over a
// host directory; started runs once the first watch is installed.
func driveWatch(t *testing.T, script string, prepare, started func(root string)) {
	t.Helper()
	p := watchTestProcess(t, script, "")
	manager := NewManager()
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if err := manager.Stop(ctx); err != nil {
			t.Error(err)
		}
	})
	root := t.TempDir()
	prepare(root)
	events := make(chan process.Event, 1024)
	ctx := ctxapi.NewRootContext()
	ctx = fsapi.WithRegistry(ctx, watchTestRegistry{fs: watchTestFS{root: root}})
	ctx = relay.WithNode(ctx, watchTestNode{events: events})
	var out process.StepOutput
	if err := p.Step(nil, &out); err != nil {
		t.Fatal(err)
	}
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	begun := false
	for !out.IsDone() {
		for _, y := range out.Yields() {
			if err := manager.Handle(ctx, y.Cmd, y.Tag, watchTestReceiver{events: events}); err != nil {
				t.Fatal(err)
			}
		}
		select {
		case e := <-events:
			if e.Type == process.EventYieldComplete && e.Error == nil && !begun {
				begun = true
				started(root)
			}
			out.Reset()
			if err := p.Step([]process.Event{e}, &out); err != nil {
				t.Fatal(err)
			}
		case <-timer.C:
			t.Fatal("watch script did not complete")
		}
	}
}

func TestLuaRecursiveWatchReportsNestedChanges(t *testing.T) {
	driveWatch(t, `local w, err = ioevents.watch("workspace", ".", {recursive = true}); assert(w, tostring(err)); local ch = w:channel(); while true do local e = ch:receive(); if e.kind == "change" and e.path == "sub/deep/file.txt" then break end end; return true`,
		func(root string) {
			if err := os.MkdirAll(filepath.Join(root, "sub", "deep"), 0700); err != nil {
				t.Fatal(err)
			}
		},
		func(root string) {
			if err := os.WriteFile(filepath.Join(root, "sub", "deep", "file.txt"), []byte("nested"), 0600); err != nil {
				t.Fatal(err)
			}
		})
}

func TestLuaWatchChannelClosesWhenItsDirectoryIsRemoved(t *testing.T) {
	driveWatch(t, `local w, err = ioevents.watch("workspace", "watched"); assert(w, tostring(err)); local ch = w:channel(); while true do local _, ok = ch:receive(); if not ok then break end end; return true`,
		func(root string) {
			if err := os.Mkdir(filepath.Join(root, "watched"), 0700); err != nil {
				t.Fatal(err)
			}
		},
		func(root string) {
			if err := os.RemoveAll(filepath.Join(root, "watched")); err != nil {
				t.Fatal(err)
			}
		})
}

func TestLuaWatchRefusesInvalidOptionsWithoutYield(t *testing.T) {
	p := watchTestProcess(t, `
		local w, err = ioevents.watch("workspace", ".", {depth = 1})
		assert(w == nil and err:kind() == "Invalid", tostring(err))
		w, err = ioevents.watch("workspace", ".", {recursive = "yes"})
		assert(w == nil and err:kind() == "Invalid", tostring(err))
		w, err = ioevents.watch("workspace", ".", true)
		assert(w == nil and err:kind() == "Invalid", tostring(err))
		return true`, "")
	var out process.StepOutput
	if err := p.Step(nil, &out); err != nil {
		t.Fatal(err)
	}
	if !out.IsDone() || out.Count() != 0 || p.LiveSubscriptionCount() != 0 {
		t.Fatalf("invalid options yielded or leaked: %+v", out)
	}
}

func TestDeliveryTurnsTheLastFreeSlotIntoARescan(t *testing.T) {
	l := lua.NewState()
	defer l.Close()
	channel := engine.NewChannel(4)
	handle := delivery(channel, Event{Kind: EventRescan, Resource: "workspace", Path: "."})
	offer := func(name string) lua.LValue {
		value := handle(context.Background(), l, pid.PID{}, "ioevents@1", []payload.Payload{payload.NewPayload(Event{Kind: EventChange, Resource: "workspace", Path: name, Operation: "write"}, payload.Golang)})
		if value != nil {
			if _, sent := channel.TrySend(value); !sent {
				t.Fatalf("delivered %s into a full channel", name)
			}
		}
		return value
	}
	kinds := []string{}
	for index := range 10 {
		if value := offer("f" + strconv.Itoa(index)); value != nil {
			kinds = append(kinds, value.(*lua.LTable).RawGetString("kind").String()+":"+value.(*lua.LTable).RawGetString("path").String())
		}
	}
	want := []string{"change:f0", "change:f1", "change:f2", "rescan:."}
	if strings.Join(kinds, ",") != strings.Join(want, ",") {
		t.Fatalf("delivered %v, want %v", kinds, want)
	}
	channel.Drain()
	value := offer("after")
	if value == nil || value.(*lua.LTable).RawGetString("path").String() != "after" {
		t.Fatal("delivery did not resume once the consumer received the rescan")
	}
}
