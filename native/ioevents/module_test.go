// SPDX-License-Identifier: MIT

package ioevents

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	lua "github.com/wippyai/go-lua"
	"github.com/wippyai/runtime/api/attrs"
	ctxapi "github.com/wippyai/runtime/api/context"
	apierror "github.com/wippyai/runtime/api/error"
	fsapi "github.com/wippyai/runtime/api/fs"
	"github.com/wippyai/runtime/api/payload"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/api/process"
	registryapi "github.com/wippyai/runtime/api/registry"
	"github.com/wippyai/runtime/api/relay"
	runtimeapi "github.com/wippyai/runtime/api/runtime"
	secapi "github.com/wippyai/runtime/api/security"
	"github.com/wippyai/runtime/runtime/lua/engine"
	fsmod "github.com/wippyai/runtime/runtime/lua/modules/fs"
)

// watchTestScope allows every action on the named resources but denied.
type watchTestScope struct {
	secapi.Scope
	allowed map[string]bool
	denied  string
}

func (s watchTestScope) Evaluate(actor secapi.Actor, action, resource string, _ attrs.Bag) secapi.Result {
	if actor.ID != "watch-owner" || !s.allowed[resource] || action == s.denied {
		return secapi.Deny
	}
	return secapi.Allow
}

type watchTestFS struct {
	fsapi.FS
	root string
}

func (f *watchTestFS) RootPath() string { return f.root }

// volumes is a filesystem registry and the registry finder over the
// fs.directory entries it holds; sources maps a host-backed entry to the
// read-only volume its meta.watch_for names.
type volumes struct {
	filesystems map[string]fsapi.FS
	sources     map[string]string
}

func (v volumes) GetFS(name string) (fsapi.FS, bool) {
	filesystem, ok := v.filesystems[name]
	return filesystem, ok
}

func (v volumes) Find(meta attrs.Bag) ([]registryapi.Entry, error) {
	if meta.GetString(".kind", "") != "fs.directory" {
		return nil, nil
	}
	var entries []registryapi.Entry
	if folder := meta.GetString("meta.watch_for", ""); folder != "" {
		for source, served := range v.sources {
			if served == folder {
				entries = append(entries, registryapi.Entry{ID: registryapi.ParseID(source), Kind: "fs.directory"})
			}
		}
		return entries, nil
	}
	for name := range v.filesystems {
		entries = append(entries, registryapi.Entry{ID: registryapi.ParseID(name), Kind: "fs.directory"})
	}
	return entries, nil
}

func hostVolume(root string) volumes {
	return volumes{filesystems: map[string]fsapi.FS{"app:workspace": &watchTestFS{root: root}}}
}

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

func watchTestProcess(t *testing.T, script, denied string, registry volumes, allowed ...string) *engine.Process {
	t.Helper()
	root := ctxapi.NewRootContext()
	root = fsapi.WithRegistry(root, registry)
	root = registryapi.WithFinder(root, registry)
	ctx, _ := ctxapi.OpenFrameContext(root)
	if err := secapi.SetActor(ctx, secapi.Actor{ID: "watch-owner"}); err != nil {
		t.Fatal(err)
	}
	permitted := map[string]bool{"app:workspace": true}
	for _, name := range allowed {
		permitted[name] = true
	}
	if err := secapi.SetScope(ctx, watchTestScope{allowed: permitted, denied: denied}); err != nil {
		t.Fatal(err)
	}
	if err := runtimeapi.SetFramePID(ctx, pid.PID{Host: "test", UniqID: "owner"}); err != nil {
		t.Fatal(err)
	}
	p, err := engine.NewProcess(engine.WithScript(script, "watch-test.lua"), engine.WithModuleBinder(func(l *lua.LState) error {
		engine.LoadModuleDef(l, engine.ChannelModule)
		engine.LoadModuleDef(l, fsmod.Module)
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

func stepDone(t *testing.T, p *engine.Process) process.StepOutput {
	t.Helper()
	var out process.StepOutput
	if err := p.Step(nil, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

func TestLuaWatchChecksCallerWatchPermissionBeforeYield(t *testing.T) {
	p := watchTestProcess(t, `local files = assert(fs.get("app:workspace")); local w, err = ioevents.watch(files); assert(w == nil and err:kind() == "PermissionDenied", tostring(err)); return true`,
		"ioevents.watch", hostVolume(t.TempDir()))
	out := stepDone(t, p)
	if !out.IsDone() || out.Count() != 0 || p.LiveSubscriptionCount() != 0 {
		t.Fatalf("denied watch yielded or leaked: %+v", out)
	}
}

func TestLuaWatchTakesOnlyAFilesystemHandle(t *testing.T) {
	p := watchTestProcess(t, `
		for _, given in ipairs({"app:workspace", 7, {}}) do
			local w, err = ioevents.watch(given)
			assert(w == nil and err:kind() == "Invalid", tostring(err))
		end
		return true`, "", hostVolume(t.TempDir()))
	out := stepDone(t, p)
	if !out.IsDone() || out.Count() != 0 || p.LiveSubscriptionCount() != 0 {
		t.Fatalf("a non-filesystem argument yielded or leaked: %+v", out)
	}
}

func TestLuaWatchRefusesInvalidOptionsWithoutYield(t *testing.T) {
	p := watchTestProcess(t, `
		local files = assert(fs.get("app:workspace"))
		local w, err = ioevents.watch(files, ".", {depth = 1})
		assert(w == nil and err:kind() == "Invalid", tostring(err))
		w, err = ioevents.watch(files, ".", {recursive = "yes"})
		assert(w == nil and err:kind() == "Invalid", tostring(err))
		w, err = ioevents.watch(files, ".", true)
		assert(w == nil and err:kind() == "Invalid", tostring(err))
		w, err = ioevents.watch(files, "../outside")
		assert(w == nil and err:kind() == "Invalid", tostring(err))
		return true`, "", hostVolume(t.TempDir()))
	out := stepDone(t, p)
	if !out.IsDone() || out.Count() != 0 || p.LiveSubscriptionCount() != 0 {
		t.Fatalf("invalid options yielded or leaked: %+v", out)
	}
}

// driveWatch runs script, serving its watch yields from a manager;
// started runs once the first watch is installed.
func driveWatch(t *testing.T, script string, registry volumes, started func()) {
	t.Helper()
	p := watchTestProcess(t, script, "", registry)
	manager := NewManager()
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if err := manager.Stop(ctx); err != nil {
			t.Error(err)
		}
	})
	events := make(chan process.Event, 1024)
	ctx := relay.WithNode(ctxapi.NewRootContext(), watchTestNode{events: events})
	out := stepDone(t, p)
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
				started()
			}
			out.Reset()
			if err := p.Step([]process.Event{e}, &out); err != nil {
				t.Fatal(err)
			}
		case <-timer.C:
			t.Fatal("watch script did not complete")
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
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("native watch survived close/owner exit")
		}
		time.Sleep(time.Millisecond)
	}
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0600); err != nil {
		t.Fatal(err)
	}
}

func TestLuaWatchNativeDeliveryAndCleanup(t *testing.T) {
	for _, mode := range []string{"close", "exit"} {
		t.Run(mode, func(t *testing.T) {
			script := `local files = assert(fs.get("app:workspace")); local w, err = ioevents.watch(files); assert(w, tostring(err)); local ch = w:channel(); local initial = ch:receive(); assert(initial.kind == "rescan" and initial.resource == "app:workspace" and initial.path == "."); while true do local e = ch:receive(); if e.kind == "change" and e.path == "created.txt" then break end end; `
			if mode == "close" {
				script += `assert(w:close()); assert(w:close()); local v, ok = ch:receive(); assert(v == nil and ok == false); `
			}
			root := t.TempDir()
			driveWatch(t, script+`return true`, hostVolume(root), func() { writeFile(t, filepath.Join(root, "created.txt"), "native-event") })
		})
	}
}

func TestLuaRecursiveWatchReportsNestedChanges(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "sub", "deep"), 0700); err != nil {
		t.Fatal(err)
	}
	driveWatch(t, `local files = assert(fs.get("app:workspace")); local w, err = ioevents.watch(files, "sub", {recursive = true}); assert(w, tostring(err)); local ch = w:channel(); assert(ch:receive().path == "sub"); while true do local e = ch:receive(); if e.kind == "change" and e.path == "sub/deep/file.txt" then break end end; return true`,
		hostVolume(root), func() { writeFile(t, filepath.Join(root, "sub", "deep", "file.txt"), "nested") })
}

func TestLuaWatchChannelClosesWhenItsDirectoryIsRemoved(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "watched"), 0700); err != nil {
		t.Fatal(err)
	}
	driveWatch(t, `local files = assert(fs.get("app:workspace")); local w, err = ioevents.watch(files, "watched"); assert(w, tostring(err)); local ch = w:channel(); while true do local _, ok = ch:receive(); if not ok then break end end; return true`,
		hostVolume(root), func() {
			if err := os.RemoveAll(filepath.Join(root, "watched")); err != nil {
				t.Fatal(err)
			}
		})
}

func TestLuaWatchFailedStartReleasesSubscription(t *testing.T) {
	driveWatch(t, `local files = assert(fs.get("app:workspace")); local w, err = ioevents.watch(files, "missing"); assert(w == nil and err:kind() == "NotFound", tostring(err:kind()) .. ": " .. tostring(err)); return true`,
		hostVolume(t.TempDir()), func() {})
}

func readOnly(root string) fsapi.FS {
	return fsapi.NewReadOnlyFS(os.DirFS(root).(fs.ReadDirFS))
}

func TestWatchSourceOfAReadOnlyVolumeIsTheHostEntryServingIt(t *testing.T) {
	root, other := t.TempDir(), t.TempDir()
	folder, unserved, unregistered := readOnly(root), readOnly(other), readOnly(other)
	registry := volumes{
		filesystems: map[string]fsapi.FS{"app:docs": folder, "grants:source": &watchTestFS{root: root}, "app:plain": unserved},
		sources:     map[string]string{"grants:source": "app:docs"},
	}
	ctx := registryapi.WithFinder(fsapi.WithRegistry(ctxapi.NewRootContext(), registry), registry)
	resource, resolved, err := watchSource(ctx, folder)
	if err != nil || resource != "app:docs" || resolved != root {
		t.Fatalf("read-only folder resolved to %q at %q, %v", resource, resolved, err)
	}
	for name, backend := range map[string]fsapi.FS{"unserved": unserved, "unregistered": unregistered} {
		var typed apierror.Error
		if _, _, err := watchSource(ctx, backend); !errors.As(err, &typed) || typed.Kind() != apierror.Invalid {
			t.Fatalf("%s: want Invalid, got %v", name, err)
		}
	}
}

func TestLuaWatchOfAnotherVolumeChecksThatVolume(t *testing.T) {
	registry := volumes{filesystems: map[string]fsapi.FS{"app:workspace": &watchTestFS{root: t.TempDir()},
		"other:files": &watchTestFS{root: t.TempDir()}}}
	p := watchTestProcess(t, `
		local files = assert(fs.get("other:files"))
		local w, err = ioevents.watch(files)
		assert(w == nil and err:kind() == "PermissionDenied" and tostring(err):find("other:files", 1, true), tostring(err))
		return true`, "ioevents.watch", registry, "other:files")
	out := stepDone(t, p)
	if !out.IsDone() || out.Count() != 0 {
		t.Fatalf("watch of a volume without its grant yielded: %+v", out)
	}
}

func TestDeliveryTurnsTheLastFreeSlotIntoARescan(t *testing.T) {
	l := lua.NewState()
	defer l.Close()
	channel := engine.NewChannel(4)
	handle := delivery(channel, Event{Kind: EventRescan, Resource: "app:workspace", Path: "."})
	offer := func(name string) lua.LValue {
		value := handle(context.Background(), l, pid.PID{}, "ioevents@1", []payload.Payload{payload.NewPayload(Event{Kind: EventChange, Resource: "app:workspace", Path: name, Operation: "write"}, payload.Golang)})
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

// TestMain installs the error metadata extractor the runtime's Lua engine
// installs at boot, so native error kinds reach Lua as they do in a node.
func TestMain(m *testing.M) {
	lua.ConfigureErrorMetadataExtractor(func(err error) *lua.ErrorMetadata {
		chain := apierror.BuildChain(err)
		if chain == nil || chain.Root() == nil {
			return nil
		}
		root := chain.Root()
		return &lua.ErrorMetadata{Kind: lua.Kind(root.Kind), Retryable: root.Retryable}
	})
	os.Exit(m.Run())
}
