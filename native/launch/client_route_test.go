//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/wippyai/bee/native/hive/rendezvous"
)

func TestWaitEnrolledReturnsCorruptRendezvousImmediately(t *testing.T) {
	state := t.TempDir()
	if err := os.MkdirAll(ownerDirectory(state), 0o700); err != nil {
		t.Fatal(err)
	}
	directory := filepath.Join(state, rendezvous.DirectoryName)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, rendezvous.FileName), []byte(`{"version":1}`), 0o600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	started := time.Now()
	public, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	err = waitEnrolled(ctx, state, "bee-client-test", public, nil)
	if err == nil || errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("corrupt rendezvous result = %v", err)
	}
	if time.Since(started) > time.Second {
		t.Fatalf("corrupt rendezvous took %s to return", time.Since(started))
	}
}

func TestWaitEnrolledDoesNotMaskFailureWithReadyEnrollment(t *testing.T) {
	ctx := context.Background()
	state := t.TempDir()
	descriptor := fakeDescriptor(t)
	descriptor.Launch = "0123456789abcdef0123456789abcdef"
	store, err := rendezvous.New(filepath.Join(state, rendezvous.DirectoryName))
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Publish(ctx, descriptor); err != nil {
		t.Fatal(err)
	}
	enrollment, err := rendezvous.NewEnrollment(ownerDirectory(state))
	if err != nil {
		t.Fatal(err)
	}
	if err := enrollment.Initialize(ctx, descriptor.Execution, make([]byte, 32)); err != nil {
		t.Fatal(err)
	}
	public, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := enrollment.Register(ctx, descriptor.Execution, "bee-client-test", public); err != nil {
		t.Fatal(err)
	}
	monitor, err := beginStartup(ctx, state, descriptor.Launch, "")
	if err != nil {
		t.Fatal(err)
	}
	defer monitor.stop()
	monitor.cancel()
	<-monitor.done
	monitor.mutex.Lock()
	monitor.snapshot.Ready = true
	monitor.snapshot.Error = "exact published startup failure"
	monitor.dirty = true
	monitor.mutex.Unlock()
	if err := monitor.flush(); err != nil {
		t.Fatal(err)
	}
	if err := waitEnrolled(ctx, state, "bee-client-test", public, nil); err == nil || err.Error() != "exact published startup failure" {
		t.Fatalf("masked failure as readiness: %v", err)
	}
	monitor.mutex.Lock()
	monitor.snapshot.Error = ""
	monitor.dirty = true
	monitor.mutex.Unlock()
	if err := monitor.flush(); err != nil {
		t.Fatal(err)
	}
	cause := errors.New("observed owner exit before enrollment")
	if err := waitEnrolled(ctx, state, "bee-client-test", public, func() error { return cause }); !errors.Is(err, cause) {
		t.Fatalf("masked supervision with readiness: %v", err)
	}
}
