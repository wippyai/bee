// SPDX-License-Identifier: MIT
package rendezvous

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestSharedEnrollmentConcurrentEnsurePreservesPeers(t *testing.T) {
	directory := t.TempDir()
	if err := os.Chmod(directory, 0700); err != nil {
		t.Fatal(err)
	}
	enrollment, err := NewEnrollment(directory)
	if err != nil {
		t.Fatal(err)
	}
	type result struct {
		epoch    string
		snapshot Snapshot
		err      error
	}
	results := make(chan result, 8)
	for range 8 {
		go func() {
			epoch, snapshot, err := enrollment.EnsureShared(context.Background())
			results <- result{epoch, snapshot, err}
		}()
	}
	var first result
	for i := 0; i < 8; i++ {
		current := <-results
		if current.err != nil {
			t.Fatal(current.err)
		}
		if i == 0 {
			first = current
		} else if first.epoch != current.epoch || !bytes.Equal(first.snapshot.GossipKey(), current.snapshot.GossipKey()) {
			t.Fatal("concurrent projects created different Hive credentials")
		}
	}
	public, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	lease, _, err := enrollment.RegisterHeld(context.Background(), first.epoch, "project-A", public)
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Close(context.Background())
	epoch, snapshot, err := enrollment.EnsureShared(context.Background())
	if err != nil || epoch != first.epoch {
		t.Fatal("Hive epoch changed", err)
	}
	found, ok := snapshot.PeerKey("project-A")
	if !ok || !bytes.Equal(found, public) {
		t.Fatal("new project erased existing enrollment")
	}
}

func TestSharedEnrollmentRefusesMalformedExistingRecord(t *testing.T) {
	directory := t.TempDir()
	if err := os.Chmod(directory, 0700); err != nil {
		t.Fatal(err)
	}
	enrollment, err := NewEnrollment(directory)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(directory, EnrollmentFileName)
	for _, body := range []string{"", "{}", "{broken"} {
		if err := os.WriteFile(path, []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
		if _, _, err := enrollment.EnsureShared(context.Background()); err == nil {
			t.Fatal("invalid shared enrollment replaced")
		}
		after, err := os.ReadFile(path)
		if err != nil || string(after) != body {
			t.Fatal("existing state changed", err)
		}
	}
}

func TestSharedNodeRestartReclaimsOnlyItsReleasedSlot(t *testing.T) {
	ctx := context.Background()
	directory := t.TempDir()
	if err := os.Chmod(directory, 0700); err != nil {
		t.Fatal(err)
	}
	enrollment, err := NewEnrollment(directory)
	if err != nil {
		t.Fatal(err)
	}
	epoch, _, err := enrollment.EnsureShared(ctx)
	if err != nil {
		t.Fatal(err)
	}
	public, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	old, _, err := enrollment.RegisterHeld(ctx, epoch, "project-A", public)
	if err != nil {
		t.Fatal(err)
	}
	replacement, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := enrollment.RegisterHeld(ctx, epoch, "project-A", replacement); !errors.Is(err, ErrPeerConflict) {
		t.Fatal("live node replaced", err)
	}
	// Reproduce the state left by process death: durable row, released OS slot.
	if err := old.unlock(); err != nil {
		t.Fatal(err)
	}
	fresh, _, err := enrollment.RegisterHeld(ctx, epoch, "project-A", replacement)
	if err != nil {
		t.Fatal(err)
	}
	defer fresh.Close(ctx)
	if err := old.Close(ctx); !errors.Is(err, ErrPeerConflict) {
		t.Fatal("old cleanup did not fence replacement", err)
	}
	snapshot, err := enrollment.Read(ctx, epoch)
	if err != nil {
		t.Fatal(err)
	}
	key, ok := snapshot.PeerKey("project-A")
	if !ok || !bytes.Equal(key, replacement) {
		t.Fatal("old cleanup erased replacement key")
	}
}
