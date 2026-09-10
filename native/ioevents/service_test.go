// SPDX-License-Identifier: MIT

package ioevents

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func stopManager(t *testing.T, manager *Manager) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := manager.Stop(ctx); err != nil {
		t.Fatal(err)
	}
}

func TestWatchReportsChangesAndReconciliation(t *testing.T) {
	root := t.TempDir()
	manager := NewManager()
	manager.rescanInterval = 40 * time.Millisecond
	defer stopManager(t, manager)
	events := make(chan Event, 128)
	watch, err := manager.Start(context.Background(), "owner", "project:root", root, ".", func(event Event) error { events <- event; return nil })
	if err != nil {
		t.Fatal(err)
	}
	defer watch.Close()
	if err := os.WriteFile(filepath.Join(root, "file.txt"), []byte("hello"), 0600); err != nil {
		t.Fatal(err)
	}
	deadline := time.NewTimer(3 * time.Second)
	defer deadline.Stop()
	changes, rescans := 0, 0
	for changes == 0 || rescans < 2 {
		select {
		case event := <-events:
			if event.Resource != "project:root" || !filepath.IsLocal(event.Path) {
				t.Fatalf("invalid event: %+v", event)
			}
			if event.Kind == "change" && event.Path == "file.txt" {
				changes++
			}
			if event.Kind == "rescan" {
				rescans++
			}
		case <-deadline.C:
			t.Fatalf("missing events: changes=%d rescans=%d", changes, rescans)
		}
	}
}

func TestWatchRejectsTraversalAndSymlinkEscape(t *testing.T) {
	root, outside := t.TempDir(), t.TempDir()
	if err := os.Symlink(outside, filepath.Join(root, "escape")); err != nil {
		t.Skip(err)
	}
	for _, path := range []string{"../outside", outside, "escape"} {
		if _, _, err := containedDirectory(root, path); err == nil {
			t.Fatalf("accepted escape %q", path)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "file"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := containedDirectory(root, "file"); err == nil {
		t.Fatal("accepted file watch")
	}
}

func TestWatchTreatsTrailingDotsAsLiteralDirectoryName(t *testing.T) {
	root := t.TempDir()
	directory := filepath.Join(root, "literal...")
	if err := os.Mkdir(directory, 0700); err != nil {
		t.Fatal(err)
	}
	manager := NewManager()
	defer stopManager(t, manager)
	events := make(chan Event, eventBuffer)
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	watch, err := manager.Start(ctx, "owner", "project:root", root, "literal...", func(event Event) error {
		select {
		case events <- event:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	})
	if err != nil {
		t.Fatal(err)
	}
	defer watch.Close()
	if err := os.WriteFile(filepath.Join(directory, "file.txt"), []byte("change"), 0600); err != nil {
		t.Fatal(err)
	}
	deadline := time.NewTimer(3 * time.Second)
	defer deadline.Stop()
	for {
		select {
		case event := <-events:
			if event.Kind == "change" && event.Path == "literal.../file.txt" {
				return
			}
		case <-deadline.C:
			t.Fatal("missing event from directory with trailing dots")
		}
	}
}

func TestOwnerCancellationReleasesWatch(t *testing.T) {
	manager := NewManager()
	defer stopManager(t, manager)
	ctx, cancel := context.WithCancel(context.Background())
	watch, err := manager.Start(ctx, "owner", "project:root", t.TempDir(), ".", func(Event) error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	cancel()
	select {
	case <-watch.Done():
	case <-time.After(3 * time.Second):
		t.Fatal("watch survived owner cancellation")
	}
	manager.mu.Lock()
	defer manager.mu.Unlock()
	if len(manager.active) != 0 || len(manager.owners) != 0 {
		t.Fatal("watch accounting survived cancellation")
	}
}

func TestWatchQuotaAndManagerShutdown(t *testing.T) {
	manager := NewManager()
	root := t.TempDir()
	for range maxOwnerWatches {
		if _, err := manager.Start(context.Background(), "owner", "project:root", root, ".", func(Event) error { return nil }); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := manager.Start(context.Background(), "owner", "project:root", root, ".", func(Event) error { return nil }); err == nil {
		t.Fatal("owner quota was not enforced")
	}
	stopManager(t, manager)
	if _, err := manager.Start(context.Background(), "new-owner", "project:root", root, ".", func(Event) error { return nil }); err == nil {
		t.Fatal("stopped service accepted watch")
	}
}
