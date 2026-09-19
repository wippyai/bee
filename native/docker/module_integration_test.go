//go:build integration

// SPDX-License-Identifier: MIT

package docker

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/moby/moby/api/types/container"
	"github.com/moby/moby/client"
	lua "github.com/wippyai/go-lua"
	ctxapi "github.com/wippyai/runtime/api/context"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/api/relay"
	runtimeapi "github.com/wippyai/runtime/api/runtime"
	secapi "github.com/wippyai/runtime/api/security"
	ttyapi "github.com/wippyai/runtime/api/tty"
	"github.com/wippyai/runtime/runtime/lua/engine"
	relaysys "github.com/wippyai/runtime/system/relay"
	secsystem "github.com/wippyai/runtime/system/security"
	ttysys "github.com/wippyai/runtime/system/tty"
)

type completionSink struct{}

func (*completionSink) Send(pkg *relay.Package) error { relay.ReleasePackage(pkg); return nil }

// Uses real runtime frames, viewport binding and terminal proxy. It does not
// substitute for Bee's broker/placement admission or application acceptance.
func TestLuaDockerAttachmentUsesFrameOwnedTerminal(t *testing.T) {
	fixtureCtx, cli, expected, _ := newContainerFixture(t)
	service := ttysys.NewService()
	defer service.Close()
	node := relaysys.NewNode("fixture")
	if err := node.RegisterHost("workers", &completionSink{}); err != nil {
		t.Fatal(err)
	}
	root := relay.WithNode(ctxapi.NewRootContext(), node)
	hostCtx, hostFrame := ctxapi.OpenFrameContext(root)
	defer hostFrame.Close()
	if err := runtimeapi.SetFramePID(hostCtx, pid.PID{Node: "fixture", Host: "workers", UniqID: "host"}); err != nil {
		t.Fatal(err)
	}
	viewport, err := service.Create(hostCtx, 40, 6)
	if err != nil {
		t.Fatal(err)
	}
	defer viewport.Close()
	binding, err := service.Binding(viewport.Grant())
	if err != nil {
		t.Fatal(err)
	}
	defer binding.Close()
	actorCtx, actorFrame := ctxapi.OpenFrameContext(root)
	defer actorFrame.Close()
	if err := runtimeapi.SetFramePID(actorCtx, pid.PID{Node: "fixture", Host: "workers", UniqID: "app"}); err != nil {
		t.Fatal(err)
	}
	if err := secapi.SetActor(actorCtx, secapi.Actor{ID: "admitted"}); err != nil {
		t.Fatal(err)
	}
	if err := secapi.SetScope(actorCtx, secsystem.NewScope([]secapi.Policy{&attachmentPolicy{resource: "host:docker/" + expected.ContainerID, expected: expected}})); err != nil {
		t.Fatal(err)
	}
	if err := actorFrame.Set(ttyapi.PortKey(), binding); err != nil {
		t.Fatal(err)
	}
	actor, err := engine.NewProcess(engine.WithScript("return true", "docker-attachment-fixture"))
	if err != nil {
		t.Fatal(err)
	}
	defer actor.Close()
	if err := actor.Init(actorCtx, "", nil); err != nil {
		t.Fatal(err)
	}
	module, err := NewModule("host:docker", cli)
	if err != nil {
		t.Fatal(err)
	}
	table, _ := module.Build()
	l := lua.NewState()
	defer l.Close()
	l.G.Owner = actor
	l.SetGlobal("docker", table)
	request := fmt.Sprintf(`{container_id=%q,image_id=%q,started_at=%q,labels={[%q]=%q}}`, expected.ContainerID, expected.ImageID, expected.StartedAt, "bee.test", expected.Labels["bee.test"])
	// Security scope inherits; a terminal port deliberately does not. The child
	// can obtain the Docker handle but cannot redeem its parent's terminal.
	childCtx, childFrame := ctxapi.OpenFrameContext(actorCtx)
	defer childFrame.Close()
	if err := runtimeapi.SetFramePID(childCtx, pid.PID{Node: "fixture", Host: "workers", UniqID: "child"}); err != nil {
		t.Fatal(err)
	}
	l.SetContext(childCtx)
	if err := l.DoString(`local p,e=docker.attach(` + request + `);assert(p~=nil and e==nil);local s,denied=p:attach_terminal();assert(s==nil and denied~=nil);p:close()`); err != nil {
		t.Fatal(err)
	}
	l.SetContext(actorCtx)
	if err := l.DoString(`local p,e=docker.attach(` + request + `);assert(p~=nil and e==nil);session,e=p:attach_terminal();assert(session~=nil and e==nil)`); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = l.DoString(`if session then session:close() end`) }()
	waitFrame := func(want string) {
		t.Helper()
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			if strings.Contains(strings.Join(viewport.Snapshot().Rows, "\n"), want) {
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
		t.Fatal("missing terminal frame", want)
	}
	waitFrame("ready")
	if err := viewport.Resize(60, 12); err != nil {
		t.Fatal(err)
	}
	if err := l.DoString(`local function send(e) local ok,err=session:send(e);if not ok then error(e.type .. ": " .. tostring(err)) end end; send({type="resize",width=60,height=12});send({type="paste",text="hello"});send({type="key",key="enter",key_type="enter",action="press"})`); err != nil {
		t.Fatal(err)
	}
	waitFrame("input=hello")
	waitFrame("12 60")
	if err := l.DoString(`assert(session:close())`); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		if err := l.DoString(`done = session:status() == "done"`); err != nil {
			t.Fatal(err)
		}
		if l.GetGlobal("done") == lua.LTrue {
			observed, err := cli.ContainerInspect(fixtureCtx, expected.ContainerID, client.ContainerInspectOptions{})
			if err != nil {
				t.Fatal(err)
			}
			if observed.Container.State.Status != container.StateExited {
				t.Fatal("terminal close did not exit the original container")
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("terminal session did not close")
}
