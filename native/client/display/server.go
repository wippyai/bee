// SPDX-License-Identifier: MIT

package display

import (
	"context"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"sync"

	ttyapi "github.com/wippyai/runtime/api/tty"
)

const maxDrainUpdates = 256

// Serve hosts the display transport bridge over an admitted connection.
//
// The trusted caller must supply the native tty.Viewport. The wire protocol never
// accepts a PID, viewport handle or grant, policy, or process source identifier.
// Pre-admission is outside the prototype boundary: authentication, grant redemption,
// and actor selection must occur before invoking Serve.
//
// NOTE ON LOCAL VIEWPORT LIMITATION:
// The supplied localViewport must be a local in-process viewport (such as the native
// Wippy in-memory TTY broker or test fake). Native tty.Viewport has no cancellable
// context interface on Send or Resize; transport cancellation unblocks network I/O
// via conn.Close() and detaches the viewport attachment, but cannot interrupt an
// arbitrary blocking remote Viewport call.
//
// Serve closes conn and detaches localViewport on detach, cancellation, or error.
// Detaching localViewport detaches this consumer attachment and NEVER terminates
// the underlying producer process. All owned goroutines are joined before Serve returns.
func Serve(ctx context.Context, conn net.Conn, localViewport ttyapi.Viewport) error {
	if ctx == nil {
		return errors.New("display: nil context")
	}
	if conn == nil {
		return errors.New("display: conn cannot be nil")
	}
	if localViewport == nil {
		return errors.New("display: localViewport cannot be nil")
	}

	// Serve owns connection and viewport attachment lifecycle.
	defer conn.Close()
	defer localViewport.Close()

	stopCh := make(chan struct{})
	var closeOnce sync.Once
	closeAll := func() {
		closeOnce.Do(func() {
			close(stopCh)
			_ = conn.Close()
		})
	}
	defer closeAll()

	// Cancellation watcher unblocks network calls via conn.Close().
	stopWatch := watchCancellation(ctx, func() {
		closeAll()
	})
	defer stopWatch()

	// 1. Handshake exchange: client must send exact protocol version.
	if err := writePacket(conn, msgHandshake{Type: "handshake", Version: ProtocolVersion}); err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return err
	}

	clientPkt, err := readPacket(conn)
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return err
	}
	msg, err := decodeWireMessage(clientPkt)
	if err != nil {
		return err
	}
	hs, ok := msg.(*msgHandshake)
	if !ok {
		return fmt.Errorf("%w: expected handshake message, got %T", ErrInvalidMessage, msg)
	}
	if hs.Version != ProtocolVersion {
		return ErrHandshakeMismatch
	}

	// 2. Publish initial snapshot.
	initSnap := localViewport.Snapshot()
	if err := validateSnapshot(initSnap); err != nil {
		return err
	}
	initRows := initSnap.Rows
	if initRows == nil {
		initRows = []string{}
	}
	initMsg := msgSnapshot{
		Type:     "snapshot",
		Revision: initSnap.Revision,
		Width:    initSnap.Width,
		Height:   initSnap.Height,
		Rows:     initRows,
		Cursor:   toWireCursor(initSnap.Cursor),
	}
	if err := writePacket(conn, initMsg); err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return err
	}
	lastSentRevision := initSnap.Revision

	// 3. Worker coordination: reader and writer loops.
	ackCh := make(chan msgAck, 64)
	var wg sync.WaitGroup
	var readerErr, writerErr error

	// Reader loop: reads typed input/resize, validates increasing sequence,
	// passes to viewport, and queues acknowledgments.
	wg.Add(1)
	go func() {
		defer wg.Done()
		defer closeAll()

		expectedSeq := uint64(1)
		for {
			pkt, err := readPacket(conn)
			if err != nil {
				if !isNormalClose(err) && ctx.Err() == nil {
					readerErr = err
				}
				return
			}

			wmsg, err := decodeWireMessage(pkt)
			if err != nil {
				readerErr = err
				return
			}

			switch m := wmsg.(type) {
			case *msgInput:
				if expectedSeq == 0 || m.Seq != expectedSeq {
					readerErr = fmt.Errorf("%w: got %d, expected %d", ErrOutOfSequence, m.Seq, expectedSeq)
					return
				}
				if expectedSeq == math.MaxUint64 {
					readerErr = fmt.Errorf("%w: sequence overflow", ErrOutOfSequence)
					return
				}
				expectedSeq++

				ev := fromWireEvent(m.Event)
				if err := validateEvent(ev); err != nil {
					readerErr = err
					return
				}

				var sendErr error
				if ev.Type == "resize" {
					sendErr = localViewport.Resize(ev.Width, ev.Height)
				} else {
					sendErr = localViewport.Send(ev)
				}

				ack := msgAck{
					Type: "ack",
					Seq:  m.Seq,
					Ok:   sendErr == nil,
				}
				if sendErr != nil {
					ack.Error = "display: viewport input rejected"
				}

				select {
				case ackCh <- ack:
				case <-stopCh:
					return
				}

			case *msgResize:
				if expectedSeq == 0 || m.Seq != expectedSeq {
					readerErr = fmt.Errorf("%w: got %d, expected %d", ErrOutOfSequence, m.Seq, expectedSeq)
					return
				}
				if expectedSeq == math.MaxUint64 {
					readerErr = fmt.Errorf("%w: sequence overflow", ErrOutOfSequence)
					return
				}
				expectedSeq++

				if err := validateResize(m.Width, m.Height); err != nil {
					readerErr = fmt.Errorf("%w: invalid resize: %w", ErrInvalidEvent, err)
					return
				}

				resizeErr := localViewport.Resize(m.Width, m.Height)
				ack := msgAck{
					Type: "ack",
					Seq:  m.Seq,
					Ok:   resizeErr == nil,
				}
				if resizeErr != nil {
					ack.Error = "display: viewport resize rejected"
				}

				select {
				case ackCh <- ack:
				case <-stopCh:
					return
				}

			case *msgDetach:
				// Clean client detach requested.
				return

			default:
				readerErr = fmt.Errorf("%w: unexpected message type %T from client", ErrInvalidMessage, wmsg)
				return
			}
		}
	}()

	// Writer loop: serializes writes to conn.
	// Frame backpressure does NOT block local host producer: snapshots are read
	// on Updates hints and coalesced to latest revision.
	wg.Add(1)
	go func() {
		defer wg.Done()
		defer closeAll()

		viewportUpdates := localViewport.Updates()

		for {
			select {
			case <-stopCh:
				return

			case ack := <-ackCh:
				if err := writePacket(conn, ack); err != nil {
					if !isNormalClose(err) && ctx.Err() == nil {
						writerErr = err
					}
					return
				}
				if err := drainAndSendAcks(conn, ackCh, stopCh); err != nil {
					if !isNormalClose(err) && ctx.Err() == nil {
						writerErr = err
					}
					return
				}

			case _, ok := <-viewportUpdates:
				if !ok {
					// Viewport was closed by producer or host.
					return
				}

				// Coalesce intermediate updates while backpressured (bounded).
				drainUpdates(viewportUpdates)

				// Flush pending input acks first.
				if err := drainAndSendAcks(conn, ackCh, stopCh); err != nil {
					if !isNormalClose(err) && ctx.Err() == nil {
						writerErr = err
					}
					return
				}

				select {
				case <-stopCh:
					return
				default:
				}

				// Read latest coalesced snapshot.
				snap := localViewport.Snapshot()
				if snap.Revision > lastSentRevision {
					if err := validateSnapshot(snap); err != nil {
						writerErr = err
						return
					}
					snapRows := snap.Rows
					if snapRows == nil {
						snapRows = []string{}
					}
					sMsg := msgSnapshot{
						Type:     "snapshot",
						Revision: snap.Revision,
						Width:    snap.Width,
						Height:   snap.Height,
						Rows:     snapRows,
						Cursor:   toWireCursor(snap.Cursor),
					}
					if err := writePacket(conn, sMsg); err != nil {
						if !isNormalClose(err) && ctx.Err() == nil {
							writerErr = err
						}
						return
					}
					lastSentRevision = snap.Revision
				}
			}
		}
	}()

	wg.Wait()

	if ctx.Err() != nil {
		return ctx.Err()
	}
	if readerErr != nil {
		return readerErr
	}
	if writerErr != nil {
		return writerErr
	}
	return nil
}

func drainUpdates(ch <-chan ttyapi.Update) {
	for i := 0; i < maxDrainUpdates; i++ {
		select {
		case _, ok := <-ch:
			if !ok {
				return
			}
		default:
			return
		}
	}
}

func drainAndSendAcks(conn net.Conn, ch <-chan msgAck, stopCh <-chan struct{}) error {
	for {
		select {
		case <-stopCh:
			return net.ErrClosed
		case ack, ok := <-ch:
			if !ok {
				return nil
			}
			if err := writePacket(conn, ack); err != nil {
				return err
			}
		default:
			return nil
		}
	}
}

func isNormalClose(err error) bool {
	if err == nil {
		return true
	}
	if errors.Is(err, io.EOF) || errors.Is(err, net.ErrClosed) || errors.Is(err, io.ErrClosedPipe) {
		return true
	}
	msg := err.Error()
	return msg == "use of closed network connection" || msg == "io: read/write on closed pipe"
}
