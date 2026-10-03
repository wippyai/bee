// SPDX-License-Identifier: MIT
package launch

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type ownerLogCapture struct {
	writes chan string
	err    error
}

func (capture *ownerLogCapture) Write(data []byte) (int, error) {
	capture.writes <- string(data)
	if capture.err != nil {
		return 0, capture.err
	}
	return len(data), nil
}

func TestOwnerLogForwardingRequiresBootAndSkipsBootLines(t *testing.T) {
	state := t.TempDir()
	path := filepath.Join(state, "owner-fixture.log")
	bootLines := "owner diagnostic before boot\nBEE_STARTUP_PHASE 1 Checking data: workspace\n"
	if err := os.WriteFile(path, []byte(bootLines), 0600); err != nil {
		t.Fatal(err)
	}
	monitor, err := beginStartup(context.Background(), state, "forwarding", "")
	if err != nil {
		t.Fatal(err)
	}
	defer monitor.stop()
	owner := monitor.snapshot
	var quiet bytes.Buffer
	if forwarder, err := beginOwnerLogForwarding(context.Background(), state, path, owner, &quiet, func() {}); err == nil || forwarder != nil {
		t.Fatal("log forwarding started before boot")
	}
	if quiet.Len() != 0 {
		t.Fatalf("forwarded boot output: %q", quiet.String())
	}
	if err := monitor.Set(context.Background(), "phase", "running"); err != nil {
		t.Fatal(err)
	}
	capture := &ownerLogCapture{writes: make(chan string, 1)}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	forwarder, err := beginOwnerLogForwarding(ctx, state, path, owner, capture, cancel)
	if err != nil {
		t.Fatal(err)
	}
	defer forwarder.stop()
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteString("owner diagnostic after boot\n"); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-capture.writes:
		if got != "owner diagnostic after boot\n" {
			t.Fatalf("forwarded output = %q", got)
		}
	case <-ctx.Done():
		t.Fatal("owner log write was not forwarded within the requested 10s wait")
	}
	if err := forwarder.stop(); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != bootLines+"owner diagnostic after boot\n" {
		t.Fatalf("full owner log = %q, %v", data, err)
	}
}

func TestOwnerLogForwardingRefusesAnotherOwnerAndStoppedState(t *testing.T) {
	state := t.TempDir()
	monitor, err := beginStartup(context.Background(), state, "elected", "")
	if err != nil {
		t.Fatal(err)
	}
	defer monitor.stop()
	if err := monitor.Set(context.Background(), "phase", "running"); err != nil {
		t.Fatal(err)
	}
	owner := monitor.snapshot
	owner.Launch = "another"
	if _, err := beginOwnerLogForwarding(context.Background(), state, "unused", owner, &bytes.Buffer{}, func() {}); err == nil || !strings.Contains(err.Error(), "different owner") {
		t.Fatalf("other owner accepted: %v", err)
	}
	owner = monitor.snapshot
	if err := monitor.stop(); err != nil {
		t.Fatal(err)
	}
	if _, err := beginOwnerLogForwarding(context.Background(), state, "unused", owner, &bytes.Buffer{}, func() {}); err == nil || !strings.Contains(err.Error(), "owner has stopped") {
		t.Fatalf("stopped owner accepted: %v", err)
	}
}

func TestOwnerLogForwardingReportsWriteFailureAndCancelsJoin(t *testing.T) {
	state := t.TempDir()
	path := filepath.Join(state, "owner-fixture.log")
	if err := os.WriteFile(path, nil, 0600); err != nil {
		t.Fatal(err)
	}
	monitor, err := beginStartup(context.Background(), state, "write-failure", "")
	if err != nil {
		t.Fatal(err)
	}
	defer monitor.stop()
	if err := monitor.Set(context.Background(), "phase", "running"); err != nil {
		t.Fatal(err)
	}
	failure := errors.New("terminal write failed")
	capture := &ownerLogCapture{writes: make(chan string, 1), err: failure}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	forwarder, err := beginOwnerLogForwarding(ctx, state, path, monitor.snapshot, capture, cancel)
	if err != nil {
		t.Fatal(err)
	}
	defer forwarder.stop()
	if err := os.WriteFile(path, []byte("post-boot diagnostic\n"), 0600); err != nil {
		t.Fatal(err)
	}
	<-ctx.Done()
	if err := forwarder.stop(); !errors.Is(err, failure) {
		t.Fatalf("write failure was masked: %v", err)
	}
}
