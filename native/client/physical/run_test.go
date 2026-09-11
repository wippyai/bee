//go:build physicalclient && !windows

// SPDX-License-Identifier: MIT
package physical

import (
	"context"
	"errors"
	"io"
	"os"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/creack/pty"
	tty "github.com/wippyai/runtime/api/tty"
	"golang.org/x/term"
)

type stalledViewport struct {
	updates        chan tty.Update
	submitted      chan struct{}
	closed         chan struct{}
	once           sync.Once
	closeOnce      sync.Once
	operationError error
	rights         tty.MountRights
}

func newViewport(rights tty.MountRights) *stalledViewport {
	return &stalledViewport{updates: make(chan tty.Update), submitted: make(chan struct{}), closed: make(chan struct{}), rights: rights}
}
func (v *stalledViewport) Grant() string  { return "" }
func (v *stalledViewport) Handle() string { return "" }
func (v *stalledViewport) Snapshot() tty.Snapshot {
	return tty.Snapshot{Width: 80, Height: 24, Revision: 1, Rows: []string{"PHYSICAL_READY"}}
}
func (v *stalledViewport) Updates() <-chan tty.Update { return v.updates }
func (v *stalledViewport) Check(_ context.Context, right string) error {
	if (right == tty.RightObserve && v.rights.Observe) || (right == tty.RightInput && v.rights.Input) || (right == tty.RightResize && v.rights.Resize) {
		return nil
	}
	return tty.ErrPermissionDenied
}
func (v *stalledViewport) Send(tty.Event) error  { panic("uncancellable send") }
func (v *stalledViewport) Resize(int, int) error { panic("uncancellable resize") }
func (v *stalledViewport) SendContext(ctx context.Context, _ tty.Event) error {
	return v.operation(ctx)
}
func (v *stalledViewport) ResizeContext(ctx context.Context, _, _ int) error { return v.operation(ctx) }
func (v *stalledViewport) operation(ctx context.Context) error {
	v.once.Do(func() { close(v.submitted) })
	select {
	case <-ctx.Done():
	case <-v.closed:
	}
	if v.operationError != nil {
		return v.operationError
	}
	return ctx.Err()
}
func (v *stalledViewport) Close() error {
	v.closeOnce.Do(func() { close(v.closed); close(v.updates) })
	return nil
}

func terminalPair(t *testing.T) (*os.File, *os.File, *term.State) {
	t.Helper()
	master, slave, err := pty.Open()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { master.Close(); slave.Close() })
	if err := pty.Setsize(slave, &pty.Winsize{Rows: 24, Cols: 80}); err != nil {
		t.Fatal(err)
	}
	before, err := term.GetState(int(slave.Fd()))
	if err != nil {
		t.Fatal(err)
	}
	return master, slave, before
}
func waitRaw(t *testing.T, slave *os.File, before *term.State) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for {
		state, err := term.GetState(int(slave.Fd()))
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(state, before) {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("client did not enter raw mode")
		}
		time.Sleep(time.Millisecond)
	}
}
func restored(t *testing.T, slave *os.File, before *term.State) {
	t.Helper()
	after, err := term.GetState(int(slave.Fd()))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(before, after) {
		t.Fatal("terminal mode not restored")
	}
}

var control = tty.MountRights{Observe: true, Input: true, Resize: true}

func TestLocalDetachRestoresTerminalWithStalledHost(t *testing.T) {
	for name, key := range map[string]byte{"detach": 0x1d, "quit": 0x11} {
		t.Run(name, func(t *testing.T) {
			master, slave, before := terminalPair(t)
			v := newViewport(control)
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			done := make(chan error, 1)
			go func() { done <- Run(ctx, v, control, slave, io.Discard) }()
			select {
			case <-v.submitted:
			case <-ctx.Done():
				t.Fatal("resize not submitted")
			}
			if _, err := master.Write([]byte{key}); err != nil {
				t.Fatal(err)
			}
			select {
			case err := <-done:
				if err != nil {
					t.Fatal(err)
				}
			case <-time.After(time.Second):
				t.Fatal("detach blocked behind host input")
			}
			restored(t, slave, before)
			select {
			case <-v.closed:
			default:
				t.Fatal("mount not closed")
			}

		})
	}
}

func TestPeerClosePreservesDeliveryFailure(t *testing.T) {
	_, slave, before := terminalPair(t)
	v := newViewport(control)
	lost := errors.New("native delivery outcome unavailable")
	v.operationError = lost
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- Run(ctx, v, control, slave, io.Discard) }()
	select {
	case <-v.submitted:
	case <-ctx.Done():
		t.Fatal("resize not submitted")
	}
	v.Close()
	select {
	case err := <-done:
		if !errors.Is(err, lost) {
			t.Fatalf("lost delivery error: %v", err)
		}
	case <-ctx.Done():
		t.Fatal("client did not exit")
	}
	restored(t, slave, before)
}

func TestObserverDetachesWithoutSendingInputOrResize(t *testing.T) {
	master, slave, before := terminalPair(t)
	rights := tty.MountRights{Observe: true}
	v := newViewport(rights)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- Run(ctx, v, rights, slave, io.Discard) }()
	waitRaw(t, slave, before)
	if _, err := master.Write([]byte("ignored\x1d")); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-ctx.Done():
		t.Fatal("observer did not detach")
	}
	select {
	case <-v.submitted:
		t.Fatal("observer forwarded input or resize")
	default:
	}
	restored(t, slave, before)
}

func TestDeniedRightsLeaveTerminalUntouched(t *testing.T) {
	_, slave, before := terminalPair(t)
	v := newViewport(tty.MountRights{Observe: true})
	err := Run(context.Background(), v, control, slave, io.Discard)
	if !errors.Is(err, tty.ErrPermissionDenied) {
		t.Fatalf("expected denial, got %v", err)
	}
	restored(t, slave, before)
	select {
	case <-v.closed:
	default:
		t.Fatal("denied attachment leaked")
	}
}

type retiringObservation struct {
	*stalledViewport
	cancel context.CancelFunc
}

func (v *retiringObservation) Check(context.Context, string) error {
	if v.cancel != nil {
		v.cancel()
	}
	return tty.ErrMountExpired
}
func TestLocalCancellationAndExternalRevocationStayDistinct(t *testing.T) {
	for _, local := range []bool{false, true} {
		_, slave, before := terminalPair(t)
		ctx, cancel := context.WithCancel(context.Background())
		view := &retiringObservation{stalledViewport: newViewport(tty.MountRights{Observe: true})}
		if local {
			view.cancel = cancel
		}
		err := Run(ctx, view, tty.MountRights{Observe: true}, slave, io.Discard)
		cancel()
		if local && err != nil {
			t.Fatal("local cancellation became external revocation", err)
		}
		if !local && !errors.Is(err, tty.ErrMountExpired) {
			t.Fatal("external revocation hidden", err)
		}
		restored(t, slave, before)
	}
}

func TestCancellationKeepsLateDeliveryFailure(t *testing.T) {
	for _, lost := range []error{errors.New("input outcome unavailable after cancellation"), tty.ErrMountExpired} {
		t.Run(lost.Error(), func(t *testing.T) {
			_, slave, before := terminalPair(t)
			view := newViewport(control)
			view.operationError = lost
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			done := make(chan error, 1)
			go func() { done <- Run(ctx, view, control, slave, io.Discard) }()
			select {
			case <-view.submitted:
			case <-time.After(3 * time.Second):
				t.Fatal("input worker did not start")
			}
			cancel()
			select {
			case err := <-done:
				if !errors.Is(err, lost) {
					t.Fatal("delivery failure erased", err)
				}
			case <-time.After(3 * time.Second):
				t.Fatal("cancel did not exit")
			}
			restored(t, slave, before)
		})
	}
}
