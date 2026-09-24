//go:build physicalclient && !windows

// SPDX-License-Identifier: MPL-2.0
// Runtime frame and mesh fixture patterns adapted from Wippy system/tty tests.
package physical

import (
	"context"
	"errors"
	"io"
	"sync"
	"testing"
	"time"

	"github.com/wippyai/runtime/api/attrs"
	ctxapi "github.com/wippyai/runtime/api/context"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/api/registry"
	"github.com/wippyai/runtime/api/relay"
	"github.com/wippyai/runtime/api/runtime"
	"github.com/wippyai/runtime/api/security"
	tty "github.com/wippyai/runtime/api/tty"
	relaysys "github.com/wippyai/runtime/system/relay"
	securitysys "github.com/wippyai/runtime/system/security"
	ttysys "github.com/wippyai/runtime/system/tty"
)

// This transport is a test-only pair. Production transport belongs to Wippy.
type meshPair struct {
	mu        sync.Mutex
	receivers map[string]func(string, []byte)
}
type meshEnd struct {
	pair *meshPair
	node string
}

func (m meshEnd) Receive(fn func(string, []byte)) error {
	m.pair.mu.Lock()
	defer m.pair.mu.Unlock()
	m.pair.receivers[m.node] = fn
	return nil
}
func (m meshEnd) Send(peer string, data []byte) error {
	m.pair.mu.Lock()
	fn := m.pair.receivers[peer]
	m.pair.mu.Unlock()
	if fn == nil {
		return tty.ErrServiceUnavailable
	}
	fn(m.node, data)
	return nil
}

type nativeInbox struct{ messages chan *relay.Package }

func (b *nativeInbox) Send(p *relay.Package) error {
	select {
	case b.messages <- p:
		return nil
	default:
		return errors.New("test inbox full")
	}
}

type mountPolicy struct{}

func (mountPolicy) ID() registry.ID { return registry.NewID("test", "mount") }
func (mountPolicy) Evaluate(_ security.Actor, action, _ string, _ attrs.Bag) security.Result {
	switch action {
	case "tty.mount", tty.RightObserve, tty.RightInput, tty.RightResize:
		return security.Allow
	}
	return security.Deny
}
func nativeFrame(t *testing.T, service *ttysys.Service, node, id string) context.Context {
	t.Helper()
	ctx := tty.WithService(ctxapi.NewRootContext(), service)
	router := relaysys.NewNode(node)
	if err := router.RegisterHost("test", &nativeInbox{messages: make(chan *relay.Package, 32)}); err != nil {
		t.Fatal(err)
	}
	ctx = relay.WithNode(ctx, router)
	ctx, frame := ctxapi.OpenFrameContext(ctx)
	t.Cleanup(func() { frame.Close() })
	if err := frame.Set(runtime.FramePIDKey, pid.PID{Node: node, Host: "test", UniqID: id}); err != nil {
		t.Fatal(err)
	}
	if err := security.SetActor(ctx, security.Actor{ID: id}); err != nil {
		t.Fatal(err)
	}
	if err := security.SetScope(ctx, securitysys.NewScope([]security.Policy{mountPolicy{}})); err != nil {
		t.Fatal(err)
	}
	return ctx
}

func TestNativeMeshRecipientAndRetainedViewport(t *testing.T) {
	owner, client := ttysys.NewService(), ttysys.NewService()
	defer owner.Close()
	defer client.Close()
	pair := &meshPair{receivers: make(map[string]func(string, []byte))}
	if err := owner.SetMesh("owner", meshEnd{pair, "owner"}); err != nil {
		t.Fatal(err)
	}
	if err := client.SetMesh("client", meshEnd{pair, "client"}); err != nil {
		t.Fatal(err)
	}
	ownerCtx := nativeFrame(t, owner, "owner", "desktop")
	clientCtx := nativeFrame(t, client, "client", "display")
	foreignCtx := nativeFrame(t, client, "client", "stranger")
	viewport, err := owner.Create(ownerCtx, 80, 24)
	if err != nil {
		t.Fatal(err)
	}
	binding, err := owner.Binding(viewport.Grant())
	if err != nil {
		t.Fatal(err)
	}
	port, err := binding.Resolve(ownerCtx)
	if err != nil {
		t.Fatal(err)
	}
	surface, err := port.OpenSurface(tty.SurfaceOptions{})
	if err != nil {
		t.Fatal(err)
	}
	defer surface.Close()
	if _, err := surface.Present(tty.Frame{Rows: []string{"RETAINED_NATIVE_DESKTOP"}}); err != nil {
		t.Fatal(err)
	}
	target, _ := runtime.GetFramePID(clientCtx)
	issuer := viewport.(tty.MountableViewport)
	rights := tty.MountRights{Observe: true}
	attach := func() Viewport {
		t.Helper()
		ref, err := issuer.Mount(ownerCtx, target, rights)
		if err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithTimeout(clientCtx, 3*time.Second)
		defer cancel()
		mounted, err := client.Attach(ctx, ref)
		if err != nil {
			t.Fatal(err)
		}
		native, ok := mounted.(Viewport)
		if !ok {
			t.Fatal("runtime remote viewport lacks checked cancellable API")
		}
		return native
	}
	master, slave, before := terminalPair(t)
	denied := attach()
	if err := Run(foreignCtx, denied, rights, slave, io.Discard); !errors.Is(err, tty.ErrPermissionDenied) {
		t.Fatalf("foreign recipient allowed: %v", err)
	}
	restored(t, slave, before)
	mounted := attach()
	ctx, cancel := context.WithTimeout(clientCtx, 3*time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- Run(ctx, mounted, rights, slave, io.Discard) }()
	waitRaw(t, slave, before)
	if _, err := master.Write([]byte{0x1d}); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if !errors.Is(err, ErrDetached) {
			t.Fatal(err)
		}
	case <-ctx.Done():
		t.Fatal("native viewport detach hung")
	}
	restored(t, slave, before)
	if err := mounted.Check(clientCtx, tty.RightObserve); !errors.Is(err, tty.ErrMountExpired) {
		t.Fatalf("detached mount remains usable: %v", err)
	}
	rejoined := attach()
	defer rejoined.Close()
	snapshot := rejoined.Snapshot()
	if len(snapshot.Rows) == 0 || snapshot.Rows[0] != "RETAINED_NATIVE_DESKTOP" {
		t.Fatalf("lost owner content: %#v", snapshot.Rows)
	}
}
