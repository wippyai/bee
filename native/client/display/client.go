// SPDX-License-Identifier: MIT

package display

import (
	"context"
	"errors"
	"fmt"
	"math"
	"net"
	"sync"
	"sync/atomic"

	ttyapi "github.com/wippyai/runtime/api/tty"
)

// Ack represents the host acknowledgment of an input or resize operation.
// Acceptance means viewport.Send or viewport.Resize returned on the host,
// not that downstream application actors finished processing.
type Ack struct {
	Seq uint64
	Ok  bool
	Err error
}

// Client manages the display attachment transport over an admitted net.Conn.
type Client struct {
	conn        net.Conn
	sem         chan struct{} // capacity 1 channel semaphore serializing in-flight operations
	seq         uint64        // incremented ONLY after semaphore acquisition
	seqMu       sync.Mutex
	inFlightSeq uint64               // atomic: sequence number of admitted in-flight request (0 when idle)
	ackCh       chan Ack             // capacity 1: reader sends single matching ack here
	snapshots   chan ttyapi.Snapshot // capacity 1: single latest frame buffer
	stopCh      chan struct{}
	doneCh      chan struct{}
	closeOnce   sync.Once
	initOnce    sync.Once
	errMu       sync.RWMutex
	termErr     error
	wg          sync.WaitGroup
}

func (c *Client) init() {
	c.initOnce.Do(func() {
		if c.sem == nil {
			c.sem = make(chan struct{}, 1)
			c.sem <- struct{}{}
		}
		if c.ackCh == nil {
			c.ackCh = make(chan Ack, 1)
		}
		if c.snapshots == nil {
			c.snapshots = make(chan ttyapi.Snapshot, 1)
		}
		if c.doneCh == nil {
			c.doneCh = make(chan struct{})
		}
		if c.stopCh == nil {
			c.stopCh = make(chan struct{})
		}
	})
}

// Connect performs the version handshake and establishes a display transport session
// over the provided connection. The Connect context governs ONLY the handshake and setup
// phase, not the ongoing lifetime of the returned Client.
func Connect(ctx context.Context, conn net.Conn) (*Client, error) {
	if ctx == nil {
		return nil, errors.New("display: nil context")
	}
	if conn == nil {
		return nil, errors.New("display: conn cannot be nil")
	}

	stopWatch := watchCancellation(ctx, func() {
		_ = conn.Close()
	})
	defer stopWatch()

	// 1. Read host handshake.
	hostPkt, err := readPacket(conn)
	if err != nil {
		_ = conn.Close()
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, err
	}
	msg, err := decodeWireMessage(hostPkt)
	if err != nil {
		_ = conn.Close()
		return nil, err
	}
	hs, ok := msg.(*msgHandshake)
	if !ok {
		_ = conn.Close()
		return nil, fmt.Errorf("%w: expected handshake message, got %T", ErrInvalidMessage, msg)
	}
	if hs.Version != ProtocolVersion {
		_ = conn.Close()
		return nil, ErrHandshakeMismatch
	}

	// 2. Send client handshake.
	if err := writePacket(conn, msgHandshake{Type: "handshake", Version: ProtocolVersion}); err != nil {
		_ = conn.Close()
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, err
	}

	// 3. Read initial snapshot.
	initPkt, err := readPacket(conn)
	if err != nil {
		_ = conn.Close()
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, err
	}
	initMsg, err := decodeWireMessage(initPkt)
	if err != nil {
		_ = conn.Close()
		return nil, err
	}
	sMsg, ok := initMsg.(*msgSnapshot)
	if !ok {
		_ = conn.Close()
		return nil, fmt.Errorf("%w: expected initial snapshot, got %T", ErrInvalidMessage, initMsg)
	}

	initSnap := ttyapi.Snapshot{
		Revision: sMsg.Revision,
		Width:    sMsg.Width,
		Height:   sMsg.Height,
		Rows:     sMsg.Rows,
		Cursor:   fromWireCursor(sMsg.Cursor),
	}
	if initSnap.Rows == nil {
		initSnap.Rows = []string{}
	}
	if err := validateSnapshot(initSnap); err != nil {
		_ = conn.Close()
		return nil, err
	}

	// Handshake succeeded; cancel setup watcher before starting background loops.
	stopWatch()
	if err := ctx.Err(); err != nil {
		_ = conn.Close()
		return nil, err
	}

	c := &Client{
		conn:      conn,
		sem:       make(chan struct{}, 1),
		snapshots: make(chan ttyapi.Snapshot, 1),
		stopCh:    make(chan struct{}),
		doneCh:    make(chan struct{}),
		ackCh:     make(chan Ack, 1),
	}
	c.sem <- struct{}{}
	c.snapshots <- initSnap

	c.wg.Add(1)
	go c.readLoop()

	return c, nil
}

func (c *Client) readLoop() {
	defer c.wg.Done()
	defer func() {
		c.closeOnce.Do(func() {
			close(c.stopCh)
			_ = c.conn.Close()
		})
		close(c.doneCh)
		close(c.snapshots)
	}()

	for {
		pkt, err := readPacket(c.conn)
		if err != nil {
			if !isNormalClose(err) {
				c.setErr(err)
			}
			return
		}

		wmsg, err := decodeWireMessage(pkt)
		if err != nil {
			c.setErr(err)
			return
		}

		switch m := wmsg.(type) {
		case *msgSnapshot:
			snap := ttyapi.Snapshot{
				Revision: m.Revision,
				Width:    m.Width,
				Height:   m.Height,
				Rows:     m.Rows,
				Cursor:   fromWireCursor(m.Cursor),
			}
			if snap.Rows == nil {
				snap.Rows = []string{}
			}
			if err := validateSnapshot(snap); err != nil {
				c.setErr(err)
				return
			}
			publishSnapshot(c.snapshots, snap)

		case *msgAck:
			expectedSeq := atomic.LoadUint64(&c.inFlightSeq)
			if expectedSeq == 0 || m.Seq != expectedSeq || !atomic.CompareAndSwapUint64(&c.inFlightSeq, expectedSeq, 0) {
				c.setErr(fmt.Errorf("%w: unexpected, wrong, or duplicate ack seq %d (expected %d)", ErrOutOfSequence, m.Seq, expectedSeq))
				return
			}

			var ackErr error
			if !m.Ok {
				if m.Error != "" {
					ackErr = errors.New(m.Error)
				} else {
					ackErr = errors.New("display: request rejected by host")
				}
			}
			ack := Ack{Seq: m.Seq, Ok: m.Ok, Err: ackErr}

			select {
			case c.ackCh <- ack:
			case <-c.stopCh:
				return
			}

		case *msgDetach:
			return

		default:
			c.setErr(fmt.Errorf("%w: unexpected message %T", ErrInvalidMessage, wmsg))
			return
		}
	}
}

func publishSnapshot(ch chan ttyapi.Snapshot, snap ttyapi.Snapshot) {
	select {
	case ch <- snap:
	default:
		select {
		case <-ch:
		default:
		}
		select {
		case ch <- snap:
		default:
		}
	}
}

// SendEvent sends a typed terminal event with a monotonically increasing sequence number
// and awaits its acknowledgment. Input is validated before admission. If canceled before
// semaphore admission, the request was not submitted and no sequence is consumed.
// If canceled while Write or ack wait is pending, the connection is closed to unblock Write
// and ErrUncertainDelivery is returned without replay.
func (c *Client) SendEvent(ctx context.Context, ev ttyapi.Event) (Ack, error) {
	return c.executeRequest(ctx, func() error {
		return validateEvent(ev)
	}, func(seq uint64) any {
		return msgInput{
			Type:  "input",
			Seq:   seq,
			Event: toWireEvent(ev),
		}
	})
}

// Resize submits a window resize with a monotonically increasing sequence number
// and awaits acknowledgment.
func (c *Client) Resize(ctx context.Context, width, height int) (Ack, error) {
	return c.executeRequest(ctx, func() error {
		if err := validateResize(width, height); err != nil {
			return fmt.Errorf("%w: %w", ErrInvalidEvent, err)
		}
		return nil
	}, func(seq uint64) any {
		return msgResize{
			Type:   "resize",
			Seq:    seq,
			Width:  width,
			Height: height,
		}
	})
}

func (c *Client) executeRequest(ctx context.Context, validate func() error, createMsg func(seq uint64) any) (Ack, error) {
	if ctx == nil {
		return Ack{}, errors.New("display: nil context")
	}

	if err := ctx.Err(); err != nil {
		return Ack{}, err
	}

	// Validate input BEFORE effects.
	if err := validate(); err != nil {
		return Ack{}, err
	}

	c.init()

	select {
	case <-c.doneCh:
		return Ack{}, ErrClosed
	default:
	}

	// Cancellable channel semaphore: serialize one in-flight request.
	select {
	case <-c.sem:
	case <-ctx.Done():
		// Waiting-to-acquire cancellation is known not submitted; no sequence allocated.
		return Ack{}, ctx.Err()
	case <-c.doneCh:
		return Ack{}, ErrClosed
	}

	if err := ctx.Err(); err != nil {
		c.releaseSem()
		return Ack{}, err
	}

	// Double check session termination after acquiring semaphore.
	select {
	case <-c.doneCh:
		c.releaseSem()
		return Ack{}, ErrClosed
	default:
	}

	// Sequence allocation and wire ordering must be one serialized operation;
	// no numbering gaps for requests canceled before admission.
	c.seqMu.Lock()
	if c.seq == math.MaxUint64 {
		c.seqMu.Unlock()
		c.releaseSem()
		return Ack{}, errors.New("display: sequence overflow")
	}
	seq := c.seq + 1
	packet, err := encodePacket(createMsg(seq))
	if err != nil {
		c.seqMu.Unlock()
		c.releaseSem()
		return Ack{}, err
	}
	c.seq = seq
	c.seqMu.Unlock()

	atomic.StoreUint64(&c.inFlightSeq, seq)
	defer func() {
		atomic.StoreUint64(&c.inFlightSeq, 0)
		select {
		case <-c.ackCh:
		default:
		}
		c.releaseSem()
	}()

	// For admitted request, cancellation while Write or ack wait is pending
	// must close the connection, unblock Write and return ErrUncertainDelivery; don't replay.
	stopCancel := watchCancellation(ctx, func() {
		_ = c.conn.Close()
	})
	defer stopCancel()

	if err := writeEncodedPacket(c.conn, packet); err != nil {
		c.setErr(err)
		_ = c.conn.Close()
		return Ack{Seq: seq, Ok: false, Err: ErrUncertainDelivery}, ErrUncertainDelivery
	}

	select {
	case ack := <-c.ackCh:
		return ack, ack.Err
	case <-ctx.Done():
		return Ack{Seq: seq, Ok: false, Err: ErrUncertainDelivery}, ErrUncertainDelivery
	case <-c.doneCh:
		select {
		case ack := <-c.ackCh:
			return ack, ack.Err
		default:
		}
		return Ack{Seq: seq, Ok: false, Err: ErrUncertainDelivery}, ErrUncertainDelivery
	}
}

func (c *Client) releaseSem() {
	select {
	case c.sem <- struct{}{}:
	default:
	}
}

// Snapshots returns the receive channel for full display snapshots.
func (c *Client) Snapshots() <-chan ttyapi.Snapshot {
	c.init()
	return c.snapshots
}

// NextSnapshot returns the next display snapshot, blocking until one is available
// or the context/connection is closed.
func (c *Client) NextSnapshot(ctx context.Context) (ttyapi.Snapshot, error) {
	if ctx == nil {
		return ttyapi.Snapshot{}, errors.New("display: nil context")
	}
	c.init()

	select {
	case <-c.doneCh:
		return ttyapi.Snapshot{}, ErrClosed
	default:
	}

	select {
	case snap, ok := <-c.snapshots:
		if !ok {
			return ttyapi.Snapshot{}, ErrClosed
		}
		return snap, nil
	case <-ctx.Done():
		return ttyapi.Snapshot{}, ctx.Err()
	case <-c.doneCh:
		return ttyapi.Snapshot{}, ErrClosed
	}
}

// Run executes a snapshot consumer loop until context cancellation, consumer error,
// or session closure.
func (c *Client) Run(ctx context.Context, onSnapshot func(ttyapi.Snapshot) error) error {
	if ctx == nil {
		return errors.New("display: nil context")
	}
	for {
		snap, err := c.NextSnapshot(ctx)
		if err != nil {
			if errors.Is(err, ErrClosed) {
				return nil
			}
			return err
		}
		if err := onSnapshot(snap); err != nil {
			return err
		}
	}
}

// Close immediately closes net.Conn before waiting, never trying an unbounded
// graceful detach write under writeMu. All background loops are unblocked and joined.
func (c *Client) Close() error {
	c.init()
	c.closeOnce.Do(func() {
		close(c.stopCh)
		_ = c.conn.Close()
	})
	c.wg.Wait()
	return nil
}

// Done returns a channel that is closed when the client session terminates.
func (c *Client) Done() <-chan struct{} {
	c.init()
	return c.doneCh
}

// Err returns the error that caused the client session to terminate, if any.
// Reads are synchronized with writer goroutine.
func (c *Client) Err() error {
	c.errMu.RLock()
	defer c.errMu.RUnlock()
	return c.termErr
}

func (c *Client) setErr(err error) {
	c.errMu.Lock()
	if c.termErr == nil {
		c.termErr = err
	}
	c.errMu.Unlock()
}
