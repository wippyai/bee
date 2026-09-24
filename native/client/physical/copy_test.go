//go:build physicalclient && !windows

// SPDX-License-Identifier: MIT
package physical

import (
	"bytes"
	"context"
	"errors"
	"io"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	tty "github.com/wippyai/runtime/api/tty"
	"github.com/wippyai/runtime/service/terminal"
)

type copyViewport struct {
	*stalledViewport
	keys    chan tty.Event
	revoked atomic.Bool
}

func (v *copyViewport) Check(ctx context.Context, right string) error {
	if v.revoked.Load() {
		return tty.ErrMountExpired
	}
	return v.stalledViewport.Check(ctx, right)
}

func (v *copyViewport) ResizeContext(context.Context, int, int) error { return nil }
func (v *copyViewport) SendContext(_ context.Context, event tty.Event) error {
	v.keys <- event
	return nil
}

type copyOutput struct {
	sync.Mutex
	bytes.Buffer
	wrote chan struct{}
	once  sync.Once
}

func (w *copyOutput) Write(data []byte) (int, error) {
	w.Lock()
	defer w.Unlock()
	if bytes.Contains(data, []byte("\x1b]52;")) {
		w.once.Do(func() { close(w.wrote) })
	}
	return w.Buffer.Write(data)
}

func TestPhysicalCopyAndOrdinaryInterruptRemainDistinct(t *testing.T) {
	for _, selected := range []bool{false, true} {
		t.Run(map[bool]string{false: "interrupt", true: "copy"}[selected], func(t *testing.T) {
			master, slave, before := terminalPair(t)
			view := &copyViewport{stalledViewport: newViewport(control), keys: make(chan tty.Event, 8)}
			out := &copyOutput{wrote: make(chan struct{})}
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			called := make(chan struct{}, 1)
			done := make(chan error, 1)
			go func() {
				done <- RunWithCopy(ctx, view, control, slave, out, func(context.Context) (string, bool, error) {
					called <- struct{}{}
					return "foreground\n", selected, nil
				})
			}()
			waitRaw(t, slave, before)
			if _, err := master.Write([]byte{3}); err != nil {
				t.Fatal(err)
			}
			select {
			case <-called:
			case <-ctx.Done():
				t.Fatal("copy action not queried")
			}
			_, supported := any(terminal.NewSurface(io.Discard, tty.SurfaceOptions{})).(interface{ Clipboard(string) error })
			if selected && !supported {
				select {
				case err := <-done:
					if err == nil {
						t.Fatal("unsupported copy claimed success")
					}
				case <-ctx.Done():
					t.Fatal("unsupported copy did not finish")
				}
			} else {
				if selected {
					select {
					case <-out.wrote:
					case <-ctx.Done():
						t.Fatal("copy not submitted")
					}
					if _, err := master.Write([]byte("\x1b[99;5:3uz")); err != nil {
						t.Fatal(err)
					}
					select {
					case key := <-view.keys:
						if key.Key != "z" {
							t.Fatal("copy release leaked to application", key)
						}
					case <-ctx.Done():
						t.Fatal("ordinary input did not resume after copy")
					}
				} else {
					select {
					case key := <-view.keys:
						if !key.Ctrl || key.Key != "c" {
							t.Fatal(key)
						}
					case <-ctx.Done():
						t.Fatal("application interrupt lost")
					}
				}
				if _, err := master.Write([]byte{0x1d}); err != nil {
					t.Fatal(err)
				}
				select {
				case err := <-done:
					if !errors.Is(err, ErrDetached) {
						t.Fatal(err)
					}
				case <-ctx.Done():
					t.Fatal("detach stalled")
				}
			}
			if selected && len(view.keys) != 0 {
				t.Fatal("copy also interrupted application")
			}
			if selected && supported && !bytes.Contains(out.Buffer.Bytes(), []byte("\x1b]52;c;Zm9yZWdyb3VuZAo=\x07")) {
				t.Fatal("clipboard text changed")
			}
			restored(t, slave, before)
		})
	}
}

func TestUncertainSelectionDoesNotWriteOrFallbackToInterrupt(t *testing.T) {
	master, slave, before := terminalPair(t)
	view := &copyViewport{stalledViewport: newViewport(control), keys: make(chan tty.Event, 8)}
	out := &copyOutput{wrote: make(chan struct{})}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	lost := errors.New("selection response unavailable")
	done := make(chan error, 1)
	go func() {
		done <- RunWithCopy(ctx, view, control, slave, out, func(context.Context) (string, bool, error) { return "", false, lost })
	}()
	waitRaw(t, slave, before)
	if _, err := master.Write([]byte{3}); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if !errors.Is(err, lost) {
			t.Fatal(err)
		}
	case <-ctx.Done():
		t.Fatal("copy error did not finish")
	}
	if len(view.keys) != 0 || bytes.Contains(out.Buffer.Bytes(), []byte("\x1b]52;")) {
		t.Fatal("uncertain copy produced a side effect")
	}
	restored(t, slave, before)
}

func TestRetiredMountCannotCopyAReply(t *testing.T) {
	master, slave, before := terminalPair(t)
	view := &copyViewport{stalledViewport: newViewport(control), keys: make(chan tty.Event, 8)}
	out := &copyOutput{wrote: make(chan struct{})}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() {
		done <- RunWithCopy(ctx, view, control, slave, out, func(context.Context) (string, bool, error) {
			view.revoked.Store(true)
			return "old attachment text", true, nil
		})
	}()
	waitRaw(t, slave, before)
	if _, err := master.Write([]byte{3}); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if !errors.Is(err, tty.ErrMountExpired) {
			t.Fatal(err)
		}
	case <-ctx.Done():
		t.Fatal("retired copy did not finish")
	}
	if bytes.Contains(out.Buffer.Bytes(), []byte("\x1b]52;")) || len(view.keys) != 0 {
		t.Fatal("retired copy produced output")
	}
	restored(t, slave, before)
}

func TestDefiniteCopyRefusalKeepsClientAndApplicationRunning(t *testing.T) {
	master, slave, before := terminalPair(t)
	view := &copyViewport{stalledViewport: newViewport(control), keys: make(chan tty.Event, 8)}
	out := &copyOutput{wrote: make(chan struct{})}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() {
		done <- RunWithCopy(ctx, view, control, slave, out, func(context.Context) (string, bool, error) {
			return "", false, ErrCopyRefused
		})
	}()
	waitRaw(t, slave, before)
	if _, err := master.Write([]byte("\x03\x1b[99;5:3uz")); err != nil {
		t.Fatal(err)
	}
	select {
	case key := <-view.keys:
		if key.Key != "z" {
			t.Fatal("refused copy leaked a key", key)
		}
	case err := <-done:
		t.Fatal("copy refusal stopped client", err)
	case <-ctx.Done():
		t.Fatal("input did not resume after refusal")
	}
	if _, err := master.Write([]byte{0x1d}); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if !errors.Is(err, ErrDetached) {
			t.Fatal(err)
		}
	case <-ctx.Done():
		t.Fatal("detach stalled")
	}
	if bytes.Contains(out.Buffer.Bytes(), []byte("\x1b]52;")) {
		t.Fatal("refused copy wrote clipboard")
	}
	restored(t, slave, before)
}

type cancelAtCopyCheck struct {
	*copyViewport
	armed  atomic.Bool
	cancel context.CancelFunc
}

func (v *cancelAtCopyCheck) Check(ctx context.Context, right string) error {
	if right == tty.RightObserve && v.armed.CompareAndSwap(true, false) {
		v.cancel()
	}
	return v.copyViewport.Check(ctx, right)
}

func TestCancellationDuringGrantCheckDoesNotWriteClipboard(t *testing.T) {
	master, slave, before := terminalPair(t)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	view := &cancelAtCopyCheck{copyViewport: &copyViewport{stalledViewport: newViewport(control), keys: make(chan tty.Event, 8)}, cancel: cancel}
	out := &copyOutput{wrote: make(chan struct{})}
	done := make(chan error, 1)
	go func() {
		done <- RunWithCopy(ctx, view, control, slave, out, func(context.Context) (string, bool, error) {
			view.armed.Store(true)
			return "canceled selection", true, nil
		})
	}()
	waitRaw(t, slave, before)
	if _, err := master.Write([]byte{3}); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil && !errors.Is(err, context.Canceled) {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("canceled copy did not exit")
	}
	if bytes.Contains(out.Buffer.Bytes(), []byte("\x1b]52;")) || len(view.keys) != 0 {
		t.Fatal("copy produced a side effect after cancellation during grant check")
	}
	restored(t, slave, before)
}
