// SPDX-License-Identifier: MIT
package display

import (
	"context"
	ttyapi "github.com/wippyai/runtime/api/tty"
	"net"
	"testing"
	"time"
)

func TestRootClosedUpdatesDrainReturns(t *testing.T) {
	updates := make(chan ttyapi.Update)
	close(updates)
	done := make(chan struct{})
	go func() { drainUpdates(updates); close(done) }()
	select {
	case <-done:
	case <-time.After(100 * time.Millisecond):
		t.Fatal("closed update channel spins forever")
	}
}

func TestRootInputMatchesBeeDecoder(t *testing.T) {
	for _, ev := range []ttyapi.Event{
		{Type: "key", Key: "q", KeyType: "runes"},
		{Type: "mouse", Button: "left", Action: "press", X: 0, Y: 1},
	} {
		if err := validateEvent(ev); err == nil {
			t.Errorf("acknowledge input Bee drops: %#v", ev)
		}
	}
}

func TestRootCanceledInputWriteReturns(t *testing.T) {
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	client := &Client{conn: a, doneCh: make(chan struct{}), stopCh: make(chan struct{})}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, err := client.SendEvent(ctx, ttyapi.Event{Type: "key", Key: "x", KeyType: "runes", Action: "press"})
		done <- err
	}()
	select {
	case <-done:
	case <-time.After(100 * time.Millisecond):
		b.Close()
		<-done
		t.Fatal("input remains blocked writing after its context expires")
	}
}

func TestRootMalformedHandshakeDoesNotPanic(t *testing.T) {
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	type result struct {
		err        error
		panicValue any
	}
	done := make(chan result, 1)
	go func() {
		var r result
		defer func() { r.panicValue = recover(); done <- r }()
		r.err = Serve(ctx, a, newFakeViewport(10, 10))
	}()
	if _, err := readPacket(b); err != nil {
		t.Fatal(err)
	}
	if err := writePacket(b, msgResize{Type: "resize", Seq: 1, Width: 10, Height: 10}); err != nil {
		t.Fatal(err)
	}
	select {
	case r := <-done:
		if r.panicValue != nil {
			t.Fatalf("malformed handshake panicked: %v", r.panicValue)
		}
		if r.err == nil {
			t.Fatal("accepted non-handshake message")
		}
	case <-ctx.Done():
		t.Fatal("handshake refusal did not finish")
	}
}

func TestRootAlreadyCanceledDoesNotConsumeSequence(t *testing.T) {
	for i := 0; i < 100; i++ {
		a, b := net.Pipe()
		client := &Client{conn: a}
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		_, err := client.Resize(ctx, 80, 24)
		a.Close()
		b.Close()
		if err != context.Canceled || client.seq != 0 {
			t.Fatalf("canceled request admitted: seq=%d err=%v", client.seq, err)
		}
	}
}

type shortPacketWriter struct{}

func (shortPacketWriter) Write(p []byte) (int, error) { return len(p) - 1, nil }

func TestRootShortPacketWriteRefused(t *testing.T) {
	if err := writePacket(shortPacketWriter{}, msgHandshake{Type: "handshake", Version: ProtocolVersion}); err == nil {
		t.Fatal("short write reported success")
	}
}

func TestRootEmptyPasteRoundTrip(t *testing.T) {
	packet, err := encodePacket(msgInput{Type: "input", Seq: 1, Event: toWireEvent(ttyapi.Event{Type: "paste"})})
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := decodeWireMessage(packet[4:])
	if err != nil {
		t.Fatal(err)
	}
	if ev := fromWireEvent(decoded.(*msgInput).Event); ev.Type != "paste" || ev.Paste != "" {
		t.Fatalf("paste changed: %#v", ev)
	}
}

func TestRootFullUint64RoundTrip(t *testing.T) {
	const sequence = ^uint64(0)
	packet, err := encodePacket(msgAck{Type: "ack", Seq: sequence, Ok: true})
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := decodeWireMessage(packet[4:])
	if err != nil {
		t.Fatal(err)
	}
	if decoded.(*msgAck).Seq != sequence {
		t.Fatal("sequence changed")
	}
}
