//go:build physicalclient

// SPDX-License-Identifier: MIT

// Package physical presents one admitted Bee display in a physical terminal.
package physical

import (
	"context"
	"errors"
	"io"
	"os"
	"sync"

	tty "github.com/wippyai/runtime/api/tty"
	"github.com/wippyai/runtime/service/terminal"
)

const maxPendingEvents = 256
const maxPendingBytes = 2 * 1024 * 1024

// DeliveryError preserves a failed native operation separately from observation
// retirement. The operation may have been admitted; the client never replays it.
type DeliveryError struct {
	Operation string
	Cause     error
}

func (e *DeliveryError) Error() string {
	return "physical " + e.Operation + " delivery failed: " + e.Cause.Error()
}
func (e *DeliveryError) Unwrap() error { return e.Cause }

var ErrInputOverflow = errors.New("physical client: input buffer full; viewport detached without replay")

// ErrCopyRefused means the owner definitively refused this selection and has
// reported the reason in the desktop UI. It neither interrupts the application
// nor ends the client.
var ErrCopyRefused = errors.New("copy selection refused")

// output serializes native surface writes with input-mode setup and cleanup.
type output struct {
	sync.Mutex
	writer io.Writer
}

func (o *output) Write(p []byte) (int, error) { o.Lock(); defer o.Unlock(); return o.writer.Write(p) }

type queuedEvent struct {
	event tty.Event
	bytes int
}

// Viewport is the runtime's checked, cancellable native mesh attachment.
// The caller supplies the recipient's live runtime frame in ctx.
type Viewport interface {
	tty.RemoteViewport
	tty.CheckedViewport
}

// Run owns the admitted viewport until it returns. Rights select which physical
// events to forward; the native grant still authorizes every operation.
// Run never creates a transport or a producer. The caller owns
// stdin and stdout. Canceling ctx detaches this client, without stopping the host.
// Ctrl+] and Ctrl+Q detach locally and never wait behind network input.
func Run(ctx context.Context, client Viewport, rights tty.MountRights, stdin *os.File, stdout io.Writer) (result error) {
	return RunWithCopy(ctx, client, rights, stdin, stdout, nil)
}

// CopySelection performs one session-qualified selection request for an explicit
// Ctrl+C. A false selection preserves the original application key event.
type CopySelection func(context.Context) (text string, selected bool, err error)

func RunWithCopy(ctx context.Context, client Viewport, rights tty.MountRights, stdin *os.File, stdout io.Writer, copySelection CopySelection) (result error) {
	if ctx == nil || client == nil || stdin == nil || stdout == nil {
		return errors.New("physical client: missing terminal or viewport")
	}
	defer client.Close()
	if !rights.Observe {
		return tty.ErrPermissionDenied
	}
	for _, requested := range []struct {
		enabled bool
		right   string
	}{
		{true, tty.RightObserve}, {rights.Input, tty.RightInput}, {rights.Resize, tty.RightResize},
	} {
		if requested.enabled {
			if err := client.Check(ctx, requested.right); err != nil {
				return observationError(ctx, err)
			}
		}
	}
	ctx, cancel := context.WithCancelCause(ctx)
	defer cancel(nil)
	out := &output{writer: stdout}
	surface := terminal.NewSurface(out, tty.SurfaceOptions{AlternateScreen: true, HideCursor: true, Synchronized: true})
	defer func() { result = errors.Join(result, surface.Close()) }()
	events := make(chan queuedEvent, maxPendingEvents)
	var budget sync.Mutex
	pendingBytes := 0
	sink := func(event tty.Event) {
		if ctx.Err() != nil {
			return
		}
		if event.Type == "key" && event.Action == "press" && event.Ctrl && !event.Alt && (event.Key == "]" || event.Key == "q") {
			cancel(nil)
			return
		}
		resizing := event.Type == "start" || event.Type == "resize"
		if (resizing && !rights.Resize) || (!resizing && !rights.Input) {
			return
		}
		charge := 128 + len(event.Key) + len(event.KeyType) + len(event.Action) + len(event.Button) + len(event.Paste)
		budget.Lock()
		defer budget.Unlock()
		if charge > maxPendingBytes-pendingBytes {
			cancel(ErrInputOverflow)
			return
		}
		select {
		case events <- queuedEvent{event: event, bytes: charge}:
			pendingBytes += charge
		default:
			cancel(ErrInputOverflow)
		}
	}
	reader := terminal.NewEventInputReader(stdin, out, terminal.NewRawManager(stdin), sink)
	if err := reader.Start(); err != nil {
		return err
	}
	defer func() { result = errors.Join(result, reader.Stop()) }()
	reader.EnableMouse()
	var workerErr error // read only after workers.Wait
	var workers sync.WaitGroup
	workers.Add(1)
	go func() {
		defer workers.Done()
		copyReleasePending := false
		for {
			select {
			case <-ctx.Done():
				return
			case item := <-events:
				if ctx.Err() != nil {
					return
				}
				var err error
				operation := "input"
				if item.event.Type == "key" && item.event.Action == "press" && item.event.Key == "c" {
					copyReleasePending = false
				}
				if item.event.Type == "start" || item.event.Type == "resize" {
					operation = "resize"
					err = client.ResizeContext(ctx, item.event.Width, item.event.Height)
				} else if copyReleasePending && item.event.Type == "key" && item.event.Action == "release" && item.event.Key == "c" {
					copyReleasePending = false
				} else if copySelection != nil && item.event.Type == "key" && item.event.Action == "press" && item.event.Ctrl && !item.event.Alt && item.event.Key == "c" {
					operation = "copy"
					var text string
					var selected bool
					text, selected, err = copySelection(ctx)
					refused := errors.Is(err, ErrCopyRefused)
					if refused {
						err = nil
						copyReleasePending = true
					}
					if err == nil && ctx.Err() != nil {
						err = context.Cause(ctx)
					}
					if err == nil && selected && !refused {
						err = client.Check(ctx, tty.RightObserve)
					}
					// The grant check may complete after local cancellation. Do not
					// begin physical output for a request already retired here.
					if err == nil && ctx.Err() != nil {
						err = context.Cause(ctx)
					}
					if err == nil && selected && !refused {
						clipboard, ok := any(surface).(interface{ Clipboard(string) error })
						if !ok {
							err = errors.New("physical clipboard output unsupported")
						} else {
							err = clipboard.Clipboard(text)
							copyReleasePending = err == nil
						}
					} else if err == nil && !refused {
						operation = "input"
						err = client.SendContext(ctx, item.event)
					}
				} else {
					err = client.SendContext(ctx, item.event)
				}
				budget.Lock()
				pendingBytes -= item.bytes
				budget.Unlock()
				if err != nil {
					workerErr = &DeliveryError{Operation: operation, Cause: err}
					cancel(workerErr)
					return
				}
			}
		}
	}()
	// Cancel network operations before joining the input reader or worker.
	defer func() {
		cancel(nil)
		client.Close()
		workers.Wait()
		// Mount retirement can arrive before the delivery worker reports its
		// failure. Preserve that operation error after the worker exits.
		if workerErr != nil && !errors.Is(workerErr, context.Canceled) {
			result = errors.Join(result, workerErr)
		}
	}()
	present := func() error {
		if err := client.Check(ctx, tty.RightObserve); err != nil {
			return err
		}
		snapshot := client.Snapshot()
		_, err := surface.Present(tty.Frame{Rows: snapshot.Rows, Cursor: snapshot.Cursor})
		return err
	}
	if err := present(); err != nil {
		return observationError(ctx, err)
	}
	for {
		select {
		case <-ctx.Done():
			cause := context.Cause(ctx)
			if errors.Is(cause, context.Canceled) {
				return nil
			}
			return cause
		case <-reader.Done():
			return reader.Err()
		case _, ok := <-client.Updates():
			if !ok {
				return observationError(ctx, tty.ErrMountExpired)
			}
			if err := present(); err != nil {
				return observationError(ctx, err)
			}
		}
	}
}

// A canceled local observation may race mount retirement. Report its local
// cancellation cause rather than inventing an external revocation. Delivery
// worker errors are preserved independently and are never normalized here.
func observationError(ctx context.Context, err error) error {
	if ctx.Err() != nil && errors.Is(err, tty.ErrMountExpired) {
		cause := context.Cause(ctx)
		if errors.Is(cause, context.Canceled) {
			return nil
		}
		return cause
	}
	return err
}
