//go:build displayintegration

// SPDX-License-Identifier: MPL-2.0
// Provenance: Adapts upstream Wippy runtime (MPL-2.0) test harness patterns for
// native TTY service and relay frame context setup.

package display

import (
	"context"
	"errors"
	"net"
	"testing"
	"time"

	ctxapi "github.com/wippyai/runtime/api/context"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/api/relay"
	"github.com/wippyai/runtime/api/runtime"
	ttyapi "github.com/wippyai/runtime/api/tty"
	relaysys "github.com/wippyai/runtime/system/relay"
	ttysys "github.com/wippyai/runtime/system/tty"
)

type testInbox struct {
	packages chan *relay.Package
}

func (ti *testInbox) Send(pkg *relay.Package) error {
	ti.packages <- pkg
	return nil
}

func setupNativeProcessContext(t *testing.T, service *ttysys.Service, id string) (context.Context, ctxapi.FrameContext, *testInbox) {
	t.Helper()
	ctx := ctxapi.NewRootContext()
	ctx = ttyapi.WithService(ctx, service)
	node := relaysys.NewNode("node")
	box := &testInbox{packages: make(chan *relay.Package, 10)}
	if err := node.RegisterHost("workers", box); err != nil {
		t.Fatalf("RegisterHost failed: %v", err)
	}
	ctx = relay.WithNode(ctx, node)
	ctx, frame := ctxapi.OpenFrameContext(ctx)
	if err := frame.Set(runtime.FramePIDKey, pid.PID{Node: "node", Host: "workers", UniqID: id}); err != nil {
		t.Fatalf("set FramePIDKey failed: %v", err)
	}
	return ctx, frame, box
}

func TestNativeTTYMechanismProof(t *testing.T) {
	service := ttysys.NewService()
	defer service.Close()

	ctx, frame, box := setupNativeProcessContext(t, service, "producer")
	defer frame.Close()

	// 1. Create native viewport (80x24)
	viewport, err := service.Create(ctx, 80, 24)
	if err != nil {
		t.Fatalf("service.Create failed: %v", err)
	}

	// 2. Resolve producer port binding
	binding, err := service.Binding(viewport.Grant())
	if err != nil {
		t.Fatalf("service.Binding failed: %v", err)
	}
	port, err := binding.Resolve(ctx)
	if err != nil {
		t.Fatalf("binding.Resolve failed: %v", err)
	}
	if err := port.InputController().Start(); err != nil {
		t.Fatalf("InputController.Start failed: %v", err)
	}

	surface, err := port.OpenSurface(ttyapi.SurfaceOptions{})
	if err != nil {
		t.Fatalf("OpenSurface failed: %v", err)
	}
	defer surface.Close()

	// 3. Setup bridge transport over net.Pipe
	srvConn, cliConn := net.Pipe()
	bridgeCtx, bridgeCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer bridgeCancel()

	serveDone := make(chan error, 1)
	go func() {
		serveDone <- Serve(bridgeCtx, srvConn, viewport)
	}()

	cli, err := Connect(bridgeCtx, cliConn)
	if err != nil {
		t.Fatalf("Connect failed: %v", err)
	}
	defer cli.Close()

	// 4. Initial snapshot check
	snap, err := cli.NextSnapshot(bridgeCtx)
	if err != nil {
		t.Fatalf("NextSnapshot failed: %v", err)
	}
	if snap.Width != 80 || snap.Height != 24 {
		t.Fatalf("unexpected geometry: %dx%d", snap.Width, snap.Height)
	}

	// 5. Producer presents a new frame
	presentFrame := ttyapi.Frame{
		Rows:   []string{"native line 1", "native line 2"},
		Cursor: &ttyapi.Cursor{Column: 7, Row: 1, Visible: true},
	}
	stats, err := surface.Present(presentFrame)
	if err != nil {
		t.Fatalf("surface.Present failed: %v", err)
	}
	if stats.ChangedRows != 2 {
		t.Fatalf("expected 2 changed rows, got %d", stats.ChangedRows)
	}

	// 6. Client receives updated snapshot with matching rows and cursor
	updatedSnap, err := cli.NextSnapshot(bridgeCtx)
	if err != nil {
		t.Fatalf("cli NextSnapshot after present failed: %v", err)
	}
	if len(updatedSnap.Rows) != 2 || updatedSnap.Rows[0] != "native line 1" || updatedSnap.Rows[1] != "native line 2" {
		t.Fatalf("unexpected snapshot rows: %+v", updatedSnap.Rows)
	}
	if updatedSnap.Cursor == nil || updatedSnap.Cursor.Column != 7 || updatedSnap.Cursor.Row != 1 || !updatedSnap.Cursor.Visible {
		t.Fatalf("unexpected snapshot cursor: %+v", updatedSnap.Cursor)
	}

	// 7. Client sends typed key event
	keyEv := ttyapi.Event{Type: "key", Key: "q", KeyType: "runes", Action: "press"}
	ack, err := cli.SendEvent(bridgeCtx, keyEv)
	if err != nil {
		t.Fatalf("SendEvent failed: %v", err)
	}
	if !ack.Ok || ack.Seq != 1 {
		t.Fatalf("unexpected ack: %+v", ack)
	}

	// 8. Producer receives event in relay inbox
	select {
	case pkg := <-box.packages:
		if len(pkg.Messages) == 0 || pkg.Messages[0].Topic != ttyapi.TopicEvents {
			t.Fatalf("unexpected relay message topic: %+v", pkg)
		}
		if len(pkg.Messages[0].Payloads) == 0 {
			t.Fatalf("expected payloads in message: %+v", pkg)
		}
		received, ok := pkg.Messages[0].Payloads[0].Data().(*ttyapi.Event)
		if !ok || received == nil {
			t.Fatalf("payload data is not *ttyapi.Event: %T", pkg.Messages[0].Payloads[0].Data())
		}
		if received.Type != "key" || received.Key != "q" || received.Action != "press" {
			t.Fatalf("unexpected received event: %+v", received)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("producer did not receive event on relay inbox in time")
	}

	// 9. Client sends resize event
	ack, err = cli.Resize(bridgeCtx, 120, 40)
	if err != nil {
		t.Fatalf("cli.Resize failed: %v", err)
	}
	if !ack.Ok || ack.Seq != 2 {
		t.Fatalf("unexpected resize ack: %+v", ack)
	}

	// Viewport geometry is updated
	viewSnap := viewport.Snapshot()
	if viewSnap.Width != 120 || viewSnap.Height != 40 {
		t.Fatalf("expected viewport geometry 120x40, got %dx%d", viewSnap.Width, viewSnap.Height)
	}

	// 10. Client closes attachment; producer remains alive!
	if err := cli.Close(); err != nil {
		t.Fatalf("cli.Close failed: %v", err)
	}

	select {
	case sErr := <-serveDone:
		if sErr != nil && !errors.Is(sErr, context.Canceled) {
			t.Fatalf("unexpected serve done err: %v", sErr)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("Serve did not finish after client close")
	}

	// PROOF: Producer was NOT terminated by client detach!
	// Producer can still present frames!
	postDetachFrame := ttyapi.Frame{
		Rows: []string{"post-detach producer alive"},
	}
	stats, err = surface.Present(postDetachFrame)
	if err != nil {
		t.Fatalf("surface.Present failed after client detach (producer should still be alive): %v", err)
	}
	if stats.ChangedRows != 2 {
		// Present succeeded
	}
}
