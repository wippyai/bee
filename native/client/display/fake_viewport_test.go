// SPDX-License-Identifier: MIT

package display

import (
	"context"
	"errors"
	"net"
	"sync"
	"testing"
	"time"

	ttyapi "github.com/wippyai/runtime/api/tty"
)

type fakeViewport struct {
	mu          sync.RWMutex
	grant       string
	handle      string
	snapshot    ttyapi.Snapshot
	updates     chan ttyapi.Update
	sendErr     error
	resizeErr   error
	beforeSend  func()
	sentEvents  []ttyapi.Event
	resizeCalls [][2]int
	closed      bool
	closeCalled bool
}

func newFakeViewport(w, h int) *fakeViewport {
	return &fakeViewport{
		grant:   "grant_fake",
		handle:  "handle_fake",
		updates: make(chan ttyapi.Update, 1),
		snapshot: ttyapi.Snapshot{
			Revision: 1,
			Width:    w,
			Height:   h,
			Rows:     []string{"fake line"},
			Cursor:   &ttyapi.Cursor{Column: 0, Row: 0, Visible: true},
		},
	}
}

func (f *fakeViewport) Grant() string  { return f.grant }
func (f *fakeViewport) Handle() string { return f.handle }

func (f *fakeViewport) Snapshot() ttyapi.Snapshot {
	f.mu.RLock()
	defer f.mu.RUnlock()
	return f.snapshot
}

func (f *fakeViewport) Updates() <-chan ttyapi.Update {
	return f.updates
}

func (f *fakeViewport) Send(ev ttyapi.Event) error {
	f.mu.Lock()
	hook := f.beforeSend
	f.mu.Unlock()

	if hook != nil {
		hook()
	}

	f.mu.Lock()
	defer f.mu.Unlock()
	if f.closed {
		return ttyapi.ErrViewportClosed
	}
	if f.sendErr != nil {
		return f.sendErr
	}
	f.sentEvents = append(f.sentEvents, ev)
	return nil
}

func (f *fakeViewport) Resize(w, h int) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.closed {
		return ttyapi.ErrViewportClosed
	}
	if f.resizeErr != nil {
		return f.resizeErr
	}
	f.resizeCalls = append(f.resizeCalls, [2]int{w, h})
	f.snapshot.Width = w
	f.snapshot.Height = h
	f.snapshot.Revision++
	select {
	case f.updates <- ttyapi.Update{Revision: f.snapshot.Revision}:
	default:
	}
	return nil
}

func (f *fakeViewport) Close() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if !f.closed {
		f.closed = true
		f.closeCalled = true
		close(f.updates)
	}
	return nil
}

func TestFakeViewportFaultInjection(t *testing.T) {
	fake := newFakeViewport(80, 24)
	errInjected := errors.New("injected send failure")
	fake.sendErr = errInjected

	srvConn, cliConn := net.Pipe()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	serveDone := make(chan error, 1)
	go func() {
		serveDone <- Serve(ctx, srvConn, fake)
	}()

	cli, err := Connect(ctx, cliConn)
	if err != nil {
		t.Fatalf("Connect failed: %v", err)
	}
	defer cli.Close()

	// Send event triggers injected error in Ack
	ack, err := cli.SendEvent(ctx, ttyapi.Event{Type: "key", Key: "a", KeyType: "runes", Action: "press"})
	if err == nil {
		t.Fatalf("expected error from SendEvent with injected fault")
	}
	if ack.Ok {
		t.Fatalf("expected ack.Ok == false, got true")
	}
	if ack.Err == nil || ack.Err.Error() != "display: viewport input rejected" {
		t.Fatalf("unexpected ack.Err: %v", ack.Err)
	}

	// Resize injected error
	fake.mu.Lock()
	fake.sendErr = nil
	errResizeInjected := errors.New("injected resize failure")
	fake.resizeErr = errResizeInjected
	fake.mu.Unlock()

	ack, err = cli.Resize(ctx, 100, 30)
	if err == nil {
		t.Fatalf("expected error from Resize with injected fault")
	}
	if ack.Ok {
		t.Fatalf("expected ack.Ok == false, got true")
	}
	if ack.Err == nil || ack.Err.Error() != "display: viewport resize rejected" {
		t.Fatalf("unexpected ack.Err: %v", ack.Err)
	}

	// Close client triggers clean shutdown of server
	if err := cli.Close(); err != nil {
		t.Fatalf("cli.Close failed: %v", err)
	}

	select {
	case sErr := <-serveDone:
		if sErr != nil && !errors.Is(sErr, context.Canceled) {
			t.Fatalf("unexpected serveErr: %v", sErr)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("Serve did not exit in time")
	}

	if !fake.closeCalled {
		t.Fatalf("expected Serve to detach viewport via Close()")
	}
}
