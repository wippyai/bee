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
	err = waitEnrolled(ctx, state, "bee-client-test", public)
	if err == nil || errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("corrupt rendezvous result = %v", err)
	}
	if time.Since(started) > time.Second {
		t.Fatalf("corrupt rendezvous took %s to return", time.Since(started))
	}
}
