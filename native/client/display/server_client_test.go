// SPDX-License-Identifier: MIT

package display

import (
	"context"
	"errors"
	"fmt"
	"net"
	"sync"
	"testing"
	"time"

	ttyapi "github.com/wippyai/runtime/api/tty"
)

func TestOrderedInputAck(t *testing.T) {
	fake := newFakeViewport(80, 24)
	srvConn, cliConn := net.Pipe()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	go func() {
		_ = Serve(ctx, srvConn, fake)
	}()

	cli, err := Connect(ctx, cliConn)
	if err != nil {
		t.Fatalf("Connect failed: %v", err)
	}
	defer cli.Close()

	for i := 1; i <= 10; i++ {
		ev := ttyapi.Event{Type: "key", Key: fmt.Sprintf("k%d", i), KeyType: "runes", Action: "press"}
		ack, err := cli.SendEvent(ctx, ev)
		if err != nil {
			t.Fatalf("SendEvent %d failed: %v", i, err)
		}
		if !ack.Ok {
			t.Fatalf("SendEvent %d ack not Ok", i)
		}
		if ack.Seq != uint64(i) {
			t.Fatalf("SendEvent %d got seq %d", i, ack.Seq)
		}
	}

	fake.mu.RLock()
	count := len(fake.sentEvents)
	fake.mu.RUnlock()
	if count != 10 {
		t.Fatalf("expected 10 sent events on viewport, got %d", count)
	}
}

func TestOutOfSequenceInputRejected(t *testing.T) {
	fake := newFakeViewport(80, 24)
	srvConn, cliConn := net.Pipe()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	serveDone := make(chan error, 1)
	go func() {
		serveDone <- Serve(ctx, srvConn, fake)
	}()

	// Perform manual handshake and then inject out-of-sequence input (seq 5 instead of 1)
	hostHsPkt, err := readPacket(cliConn)
	if err != nil {
		t.Fatalf("failed reading host handshake: %v", err)
	}
	msg, err := decodeWireMessage(hostHsPkt)
	if err != nil || msg.(*msgHandshake).Version != ProtocolVersion {
		t.Fatalf("invalid host handshake: %v", err)
	}

	if err := writePacket(cliConn, msgHandshake{Type: "handshake", Version: ProtocolVersion}); err != nil {
		t.Fatalf("failed sending client handshake: %v", err)
	}

	// Read initial snapshot
	if _, err := readPacket(cliConn); err != nil {
		t.Fatalf("failed reading initial snapshot: %v", err)
	}

	// Inject out-of-sequence input: seq 5
	badInput := msgInput{
		Type: "input",
		Seq:  5,
		Event: wireEvent{
			Type:    "key",
			Key:     "a",
			KeyType: "runes",
			Action:  "press",
		},
	}
	if err := writePacket(cliConn, badInput); err != nil {
		t.Fatalf("failed writing bad input: %v", err)
	}

	// Serve must return ErrOutOfSequence
	select {
	case err := <-serveDone:
		if !errors.Is(err, ErrOutOfSequence) {
			t.Fatalf("expected ErrOutOfSequence from Serve, got: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("Serve did not reject out of sequence input in time")
	}
}

func TestNetPipeSlowReaderCancellation(t *testing.T) {
	fake := newFakeViewport(80, 24)
	srvConn, cliConn := net.Pipe()
	ctx, cancel := context.WithCancel(context.Background())

	serveDone := make(chan error, 1)
	go func() {
		serveDone <- Serve(ctx, srvConn, fake)
	}()

	cli, err := Connect(ctx, cliConn)
	if err != nil {
		t.Fatalf("Connect failed: %v", err)
	}
	defer cli.Close()

	// Producer presents 50 frames into fake viewport.
	// Since fake.updates has buffer 1, updates coalesce and producer NEVER blocks.
	for i := 2; i <= 50; i++ {
		fake.mu.Lock()
		fake.snapshot.Revision = uint64(i)
		fake.snapshot.Rows = []string{fmt.Sprintf("frame %d", i)}
		select {
		case fake.updates <- ttyapi.Update{Revision: uint64(i)}:
		default:
		}
		fake.mu.Unlock()
	}

	// Now cancel context while slow/non-reading client connection exists
	cancel()

	// Both Serve and Client must unblock and terminate promptly
	select {
	case err := <-serveDone:
		if err != nil && !errors.Is(err, context.Canceled) {
			t.Fatalf("unexpected serve err on cancel: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("Serve failed to unblock on context cancellation")
	}

	select {
	case <-cli.Done():
	case <-time.After(2 * time.Second):
		t.Fatalf("Client failed to unblock on context cancellation")
	}
}

func TestNoCrossTalkTwoConnections(t *testing.T) {
	fake1 := newFakeViewport(80, 24)
	fake2 := newFakeViewport(100, 30)

	srvConn1, cliConn1 := net.Pipe()
	srvConn2, cliConn2 := net.Pipe()

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	go func() { _ = Serve(ctx, srvConn1, fake1) }()
	go func() { _ = Serve(ctx, srvConn2, fake2) }()

	cli1, err := Connect(ctx, cliConn1)
	if err != nil {
		t.Fatalf("Connect 1 failed: %v", err)
	}
	defer cli1.Close()

	cli2, err := Connect(ctx, cliConn2)
	if err != nil {
		t.Fatalf("Connect 2 failed: %v", err)
	}
	defer cli2.Close()

	// Initial snapshots are isolated
	snap1, err := cli1.NextSnapshot(ctx)
	if err != nil || snap1.Width != 80 {
		t.Fatalf("unexpected snap1: %v, %+v", err, snap1)
	}

	snap2, err := cli2.NextSnapshot(ctx)
	if err != nil || snap2.Width != 100 {
		t.Fatalf("unexpected snap2: %v, %+v", err, snap2)
	}

	// Send input only on connection 1
	_, err = cli1.SendEvent(ctx, ttyapi.Event{Type: "key", Key: "only1", KeyType: "runes", Action: "press"})
	if err != nil {
		t.Fatalf("cli1.SendEvent failed: %v", err)
	}

	// Verify only fake1 received the event
	fake1.mu.RLock()
	f1Count := len(fake1.sentEvents)
	fake1.mu.RUnlock()

	fake2.mu.RLock()
	f2Count := len(fake2.sentEvents)
	fake2.mu.RUnlock()

	if f1Count != 1 {
		t.Fatalf("expected 1 event on fake1, got %d", f1Count)
	}
	if f2Count != 0 {
		t.Fatalf("expected 0 events on fake2, got %d", f2Count)
	}

	// Update only fake2
	fake2.mu.Lock()
	fake2.snapshot.Revision = 2
	fake2.snapshot.Rows = []string{"fake2 update"}
	fake2.updates <- ttyapi.Update{Revision: 2}
	fake2.mu.Unlock()

	snap2Updated, err := cli2.NextSnapshot(ctx)
	if err != nil || len(snap2Updated.Rows) == 0 || snap2Updated.Rows[0] != "fake2 update" {
		t.Fatalf("unexpected snap2 update: %v, %+v", err, snap2Updated)
	}

	// cli1 should NOT have received that update
	select {
	case s := <-cli1.Snapshots():
		t.Fatalf("unexpected cross-talk snapshot on cli1: %+v", s)
	case <-time.After(100 * time.Millisecond):
		// Expected: no snapshot on cli1
	}
}

func TestStaleClosedConnectionNoInput(t *testing.T) {
	fake := newFakeViewport(80, 24)
	srvConn, cliConn := net.Pipe()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	go func() {
		_ = Serve(ctx, srvConn, fake)
	}()

	cli, err := Connect(ctx, cliConn)
	if err != nil {
		t.Fatalf("Connect failed: %v", err)
	}

	// Close client session
	if err := cli.Close(); err != nil {
		t.Fatalf("cli.Close failed: %v", err)
	}

	// Subsequent SendEvent must fail with ErrClosed immediately
	_, err = cli.SendEvent(ctx, ttyapi.Event{Type: "key", Key: "a", KeyType: "runes", Action: "press"})
	if !errors.Is(err, ErrClosed) {
		t.Fatalf("expected ErrClosed on closed client, got %v", err)
	}

	// Subsequent Resize must fail with ErrClosed immediately
	_, err = cli.Resize(ctx, 100, 30)
	if !errors.Is(err, ErrClosed) {
		t.Fatalf("expected ErrClosed on closed client resize, got %v", err)
	}

	// NextSnapshot must fail with ErrClosed
	_, err = cli.NextSnapshot(ctx)
	if !errors.Is(err, ErrClosed) {
		t.Fatalf("expected ErrClosed on NextSnapshot, got %v", err)
	}
}

func TestUncertainDeliveryOnConnectionDrop(t *testing.T) {
	fake := newFakeViewport(80, 24)
	srvConn, cliConn := net.Pipe()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	// When Send is called on fake viewport, close the connection while input is in flight
	fake.beforeSend = func() {
		_ = srvConn.Close()
	}

	go func() {
		_ = Serve(ctx, srvConn, fake)
	}()

	cli, err := Connect(ctx, cliConn)
	if err != nil {
		t.Fatalf("Connect failed: %v", err)
	}
	defer cli.Close()

	ack, err := cli.SendEvent(ctx, ttyapi.Event{Type: "key", Key: "in_flight", KeyType: "runes", Action: "press"})
	if !errors.Is(err, ErrUncertainDelivery) {
		t.Fatalf("expected ErrUncertainDelivery on dropped connection, got %v", err)
	}
	if ack.Ok {
		t.Fatalf("expected ack.Ok == false")
	}
}

func TestHandshakeMismatchRejection(t *testing.T) {
	fake := newFakeViewport(80, 24)
	srvConn, cliConn := net.Pipe()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	serveDone := make(chan error, 1)
	go func() {
		serveDone <- Serve(ctx, srvConn, fake)
	}()

	// Client reads server handshake
	hsPkt, err := readPacket(cliConn)
	if err != nil {
		t.Fatalf("readPacket failed: %v", err)
	}
	msg, err := decodeWireMessage(hsPkt)
	if err != nil || msg.(*msgHandshake).Version != ProtocolVersion {
		t.Fatalf("invalid server handshake: %v", err)
	}

	// Client responds with wrong version
	badHs := msgHandshake{Type: "handshake", Version: "bee.display.v999"}
	if err := writePacket(cliConn, badHs); err != nil {
		t.Fatalf("writePacket failed: %v", err)
	}

	select {
	case err := <-serveDone:
		if !errors.Is(err, ErrHandshakeMismatch) {
			t.Fatalf("expected ErrHandshakeMismatch, got %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("Serve did not reject handshake mismatch in time")
	}
}

func TestClientMalformedHandshakeNoPanic(t *testing.T) {
	srvConn, cliConn := net.Pipe()
	defer srvConn.Close()
	defer cliConn.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	connectDone := make(chan error, 1)
	go func() {
		_, err := Connect(ctx, cliConn)
		connectDone <- err
	}()

	// Server sends non-handshake message (e.g. detach) instead of handshake
	badMsg := msgDetach{Type: "detach", Reason: "wrong msg"}
	if err := writePacket(srvConn, badMsg); err != nil {
		t.Fatalf("writePacket failed: %v", err)
	}

	select {
	case err := <-connectDone:
		if err == nil {
			t.Fatal("expected Connect to fail on malformed handshake message")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Connect did not return in time")
	}
}

func TestQueuedVsInFlightCancellation(t *testing.T) {
	srvConn, cliConn := net.Pipe()
	defer srvConn.Close()
	defer cliConn.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	fake := newFakeViewport(80, 24)
	go func() {
		_ = Serve(ctx, srvConn, fake)
	}()

	cli, err := Connect(ctx, cliConn)
	if err != nil {
		t.Fatalf("Connect failed: %v", err)
	}
	defer cli.Close()

	// Slow down fake send to make request 1 stay in-flight
	gate := make(chan struct{})
	fake.beforeSend = func() {
		<-gate
	}

	// 1. Caller 1: admitted, in flight
	req1Done := make(chan Ack, 1)
	go func() {
		ack, _ := cli.SendEvent(ctx, ttyapi.Event{Type: "key", Key: "1", KeyType: "runes", Action: "press"})
		req1Done <- ack
	}()

	// Wait for caller 1 to acquire semaphore
	time.Sleep(30 * time.Millisecond)

	// 2. Caller 2: attempts SendEvent with a context that cancels while waiting to acquire sem
	ctxQueued, cancelQueued := context.WithTimeout(ctx, 20*time.Millisecond)
	defer cancelQueued()
	_, errQueued := cli.SendEvent(ctxQueued, ttyapi.Event{Type: "key", Key: "2", KeyType: "runes", Action: "press"})
	if !errors.Is(errQueued, context.DeadlineExceeded) {
		t.Fatalf("expected DeadlineExceeded for queued request, got: %v", errQueued)
	}

	// 3. Unblock caller 1
	close(gate)
	ack1 := <-req1Done
	if !ack1.Ok || ack1.Seq != 1 {
		t.Fatalf("unexpected ack1: %+v", ack1)
	}

	// 4. Caller 3: admitted after caller 1. Must receive seq 2 (no gap from canceled caller 2!)
	ack3, err3 := cli.SendEvent(ctx, ttyapi.Event{Type: "key", Key: "3", KeyType: "runes", Action: "press"})
	if err3 != nil {
		t.Fatalf("SendEvent 3 failed: %v", err3)
	}
	if !ack3.Ok || ack3.Seq != 2 {
		t.Fatalf("expected seq 2 for caller 3 (no gap), got seq %d", ack3.Seq)
	}
}

func TestCloseWithBlockedWriter(t *testing.T) {
	srvConn, cliConn := net.Pipe()
	defer srvConn.Close()
	defer cliConn.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	fake := newFakeViewport(80, 24)
	go func() {
		_ = Serve(ctx, srvConn, fake)
	}()

	cli, err := Connect(ctx, cliConn)
	if err != nil {
		t.Fatalf("Connect failed: %v", err)
	}

	// Close must unblock and terminate immediately without hanging
	closeDone := make(chan error, 1)
	go func() {
		closeDone <- cli.Close()
	}()

	select {
	case err := <-closeDone:
		if err != nil {
			t.Fatalf("cli.Close returned error: %v", err)
		}
	case <-time.After(500 * time.Millisecond):
		t.Fatal("cli.Close blocked or hung")
	}
}

func TestConcurrentCallersPreservingSequence(t *testing.T) {
	fake := newFakeViewport(80, 24)
	srvConn, cliConn := net.Pipe()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	go func() {
		_ = Serve(ctx, srvConn, fake)
	}()

	cli, err := Connect(ctx, cliConn)
	if err != nil {
		t.Fatalf("Connect failed: %v", err)
	}
	defer cli.Close()

	const numCalls = 10
	type result struct {
		seq uint64
		err error
	}
	results := make(chan result, numCalls)

	var startWg sync.WaitGroup
	startWg.Add(numCalls)

	for i := 0; i < numCalls; i++ {
		go func(idx int) {
			startWg.Done()
			startWg.Wait() // maximize concurrency
			ack, err := cli.SendEvent(ctx, ttyapi.Event{
				Type:    "key",
				Key:     fmt.Sprintf("k%d", idx),
				KeyType: "runes",
				Action:  "press",
			})
			results <- result{seq: ack.Seq, err: err}
		}(i)
	}

	seenSeqs := make(map[uint64]bool)
	for i := 0; i < numCalls; i++ {
		res := <-results
		if res.err != nil {
			t.Fatalf("concurrent SendEvent failed: %v", res.err)
		}
		if res.seq < 1 || res.seq > numCalls {
			t.Fatalf("unexpected sequence %d", res.seq)
		}
		if seenSeqs[res.seq] {
			t.Fatalf("duplicate sequence %d detected", res.seq)
		}
		seenSeqs[res.seq] = true
	}
}

func TestDuplicateAckRejected(t *testing.T) {
	srvConn, cliConn := net.Pipe()
	defer srvConn.Close()
	defer cliConn.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	// Perform server handshake
	go func() {
		_ = writePacket(srvConn, msgHandshake{Type: "handshake", Version: ProtocolVersion})
		clientHs, _ := readPacket(srvConn)
		_ = clientHs
		// send initial snapshot
		_ = writePacket(srvConn, msgSnapshot{
			Type:     "snapshot",
			Revision: 1,
			Width:    80,
			Height:   24,
			Rows:     []string{},
		})

		// Read client input
		pkt, err := readPacket(srvConn)
		if err != nil {
			return
		}
		msg, _ := decodeWireMessage(pkt)
		inputMsg, ok := msg.(*msgInput)
		if !ok {
			return
		}

		// Send valid ack
		_ = writePacket(srvConn, msgAck{Type: "ack", Seq: inputMsg.Seq, Ok: true})
		// Send DUPLICATE ack immediately!
		_ = writePacket(srvConn, msgAck{Type: "ack", Seq: inputMsg.Seq, Ok: true})
	}()

	cli, err := Connect(ctx, cliConn)
	if err != nil {
		t.Fatalf("Connect failed: %v", err)
	}
	defer cli.Close()

	// Send event
	ack, err := cli.SendEvent(ctx, ttyapi.Event{Type: "key", Key: "a", KeyType: "runes", Action: "press"})
	if err != nil {
		t.Fatalf("SendEvent failed: %v", err)
	}
	if !ack.Ok || ack.Seq != 1 {
		t.Fatalf("unexpected ack: %+v", ack)
	}

	// Duplicate ack should cause reader to reject and close doneCh
	select {
	case <-cli.Done():
		if !errors.Is(cli.Err(), ErrOutOfSequence) {
			t.Fatalf("expected ErrOutOfSequence for duplicate ack, got %v", cli.Err())
		}
	case <-time.After(1 * time.Second):
		t.Fatal("client did not terminate on duplicate ack")
	}
}

func TestEmptyInitialNativeViewport(t *testing.T) {
	// Fake viewport with nil Rows and valid geometry (80x24)
	fake := newFakeViewport(80, 24)
	fake.snapshot.Rows = nil

	srvConn, cliConn := net.Pipe()
	defer srvConn.Close()
	defer cliConn.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	go func() {
		_ = Serve(ctx, srvConn, fake)
	}()

	cli, err := Connect(ctx, cliConn)
	if err != nil {
		t.Fatalf("Connect with empty initial viewport failed: %v", err)
	}
	defer cli.Close()

	snap, err := cli.NextSnapshot(ctx)
	if err != nil {
		t.Fatalf("NextSnapshot failed: %v", err)
	}
	if snap.Width != 80 || snap.Height != 24 {
		t.Fatalf("unexpected geometry: %dx%d", snap.Width, snap.Height)
	}
	if snap.Rows == nil {
		t.Fatal("expected non-nil (empty slice) rows")
	}
	if len(snap.Rows) != 0 {
		t.Fatalf("expected 0 rows, got %d", len(snap.Rows))
	}

	// 0 geometry must be rejected as invalid snapshot
	fakeZero := newFakeViewport(0, 0)
	fakeZero.snapshot.Width = 0
	fakeZero.snapshot.Height = 0

	sZeroConn, cZeroConn := net.Pipe()
	defer sZeroConn.Close()
	defer cZeroConn.Close()

	serveZeroErr := make(chan error, 1)
	go func() {
		serveZeroErr <- Serve(ctx, sZeroConn, fakeZero)
	}()

	_, _ = Connect(ctx, cZeroConn)
	select {
	case err := <-serveZeroErr:
		if !errors.Is(err, ErrInvalidSnapshot) {
			t.Fatalf("expected ErrInvalidSnapshot for 0 geometry, got: %v", err)
		}
	case <-time.After(1 * time.Second):
		t.Fatal("Serve with 0 geometry did not reject in time")
	}
}
