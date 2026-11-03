// SPDX-License-Identifier: MIT

package ioevents

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	apierror "github.com/wippyai/runtime/api/error"
)

func stopManager(t *testing.T, manager *Manager) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := manager.Stop(ctx); err != nil {
		t.Fatal(err)
	}
}

// collect starts a watch whose events arrive on the returned channel.
func collect(t *testing.T, manager *Manager, root, relative string, recursive bool) (*Watch, chan Event) {
	t.Helper()
	events := make(chan Event, 4096)
	watch, err := manager.Start(t.Context(), "owner", "project:root", root, relative, recursive, func(event Event) error {
		events <- event
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(watch.Close)
	return watch, events
}

// await returns the first event matching want, failing on any rescan the
// test does not expect.
func await(t *testing.T, events chan Event, want func(Event) bool) Event {
	t.Helper()
	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	for {
		select {
		case event := <-events:
			if want(event) {
				return event
			}
			if event.Kind == EventRescan {
				t.Fatalf("unexpected rescan: %+v", event)
			}
		case <-deadline.C:
			t.Fatal("expected event did not arrive")
		}
	}
}

func change(path string) func(Event) bool {
	return func(event Event) bool { return event.Kind == EventChange && event.Path == path }
}

func rescan(path string) func(Event) bool {
	return func(event Event) bool { return event.Kind == EventRescan && event.Path == path }
}

func write(t *testing.T, path string) {
	t.Helper()
	if err := os.WriteFile(path, []byte("change"), 0600); err != nil {
		t.Fatal(err)
	}
}

func TestWatchRescansOnceAtStartThenReportsChanges(t *testing.T) {
	root := t.TempDir()
	manager := NewManager()
	defer stopManager(t, manager)
	_, events := collect(t, manager, root, ".", false)
	first := <-events
	if first.Kind != EventRescan || first.Path != "." || first.Resource != "project:root" {
		t.Fatalf("first event is not the start rescan: %+v", first)
	}
	for index := range 3 {
		name := "file-" + strconv.Itoa(index) + ".txt"
		write(t, filepath.Join(root, name))
		await(t, events, change(name))
	}
}

func TestRecursiveWatchFollowsExistingAndNewDirectories(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "docs", "deep"), 0700); err != nil {
		t.Fatal(err)
	}
	manager := NewManager()
	defer stopManager(t, manager)
	_, events := collect(t, manager, root, ".", true)
	await(t, events, rescan("."))
	write(t, filepath.Join(root, "docs", "deep", "a.txt"))
	await(t, events, change("docs/deep/a.txt"))
	if err := os.MkdirAll(filepath.Join(root, "docs", "new", "inner"), 0700); err != nil {
		t.Fatal(err)
	}
	created := await(t, events, change("docs/new"))
	if created.Operation != "create" {
		t.Fatalf("new directory reported as %q", created.Operation)
	}
	await(t, events, rescan("docs/new"))
	write(t, filepath.Join(root, "docs", "new", "inner", "b.txt"))
	await(t, events, change("docs/new/inner/b.txt"))
	if err := os.Rename(filepath.Join(root, "docs", "new"), filepath.Join(root, "moved")); err != nil {
		t.Fatal(err)
	}
	await(t, events, change("moved"))
	await(t, events, rescan("moved"))
	write(t, filepath.Join(root, "moved", "inner", "c.txt"))
	await(t, events, change("moved/inner/c.txt"))
}

func TestWatchWithoutRecursionReportsOnlyItsDirectory(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "sub"), 0700); err != nil {
		t.Fatal(err)
	}
	manager := NewManager()
	defer stopManager(t, manager)
	_, events := collect(t, manager, root, ".", false)
	await(t, events, rescan("."))
	write(t, filepath.Join(root, "sub", "hidden.txt"))
	write(t, filepath.Join(root, "sentinel.txt"))
	// One backend queue orders notices, so a notice from sub would precede
	// the sentinel.
	event := await(t, events, func(Event) bool { return true })
	if event.Path != "sentinel.txt" {
		t.Fatalf("watch reported outside its directory: %+v", event)
	}
}

func TestRecursiveWatchStaysInsideRoot(t *testing.T) {
	root, outside := t.TempDir(), t.TempDir()
	if err := os.Symlink(outside, filepath.Join(root, "link")); err != nil {
		t.Fatal(err)
	}
	manager := NewManager()
	defer stopManager(t, manager)
	watch, events := collect(t, manager, root, ".", true)
	await(t, events, rescan("."))
	if err := os.Symlink(outside, filepath.Join(root, "later")); err != nil {
		t.Fatal(err)
	}
	await(t, events, change("later"))
	write(t, filepath.Join(outside, "secret.txt"))
	write(t, filepath.Join(root, "sentinel.txt"))
	event := await(t, events, func(Event) bool { return true })
	if event.Path != "sentinel.txt" {
		t.Fatalf("recursive watch followed a symbolic link: %+v", event)
	}
	manager.mu.Lock()
	defer manager.mu.Unlock()
	canonical, err := filepath.EvalSymlinks(root)
	if err != nil {
		t.Fatal(err)
	}
	for path := range watch.followed {
		if within, err := filepath.Rel(canonical, path); err != nil || !filepath.IsLocal(within) && within != "." {
			t.Fatalf("recursive watch follows %q outside its root", path)
		}
	}
}

func TestBackendOverflowRescansTheWatchedDirectory(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "burst"), 0700); err != nil {
		t.Fatal(err)
	}
	limit, err := os.ReadFile("/proc/sys/fs/inotify/max_queued_events")
	if err != nil {
		t.Fatal(err)
	}
	queued, err := strconv.Atoi(strings.TrimSpace(string(limit)))
	if err != nil {
		t.Fatal(err)
	}
	manager := NewManager()
	defer stopManager(t, manager)
	gate := make(chan struct{})
	events := make(chan Event, 1<<20)
	held := false
	watch, err := manager.Start(t.Context(), "owner", "project:root", root, ".", true, func(event Event) error {
		// Holding the first change stalls the backend reader, so the kernel
		// queue overflows while the burst below is written.
		if event.Kind == EventChange && !held {
			held = true
			<-gate
		}
		events <- event
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	defer watch.Close()
	await(t, events, rescan("."))
	write(t, filepath.Join(root, "first.txt"))
	for index := range queued + 1024 {
		write(t, filepath.Join(root, "burst", strconv.Itoa(index)))
	}
	close(gate)
	await(t, events, change("first.txt"))
	deadline := time.NewTimer(20 * time.Second)
	defer deadline.Stop()
	for {
		select {
		case event := <-events:
			if event.Kind == EventRescan && event.Path == "." {
				return
			}
		case <-deadline.C:
			t.Fatal("backend overflow did not rescan the watched directory")
		}
	}
}

func TestBackendFailureEndsEveryWatch(t *testing.T) {
	manager := NewManager()
	defer stopManager(t, manager)
	first, _ := collect(t, manager, t.TempDir(), ".", false)
	second, _ := collect(t, manager, t.TempDir(), ".", true)
	manager.backend.Errors <- errors.New("backend read failed")
	for _, watch := range []*Watch{first, second} {
		select {
		case <-watch.Done():
		case <-time.After(3 * time.Second):
			t.Fatal("watch survived a backend failure")
		}
	}
}

func TestRemovingTheWatchedDirectoryEndsTheWatch(t *testing.T) {
	root := t.TempDir()
	directory := filepath.Join(root, "watched")
	if err := os.Mkdir(directory, 0700); err != nil {
		t.Fatal(err)
	}
	manager := NewManager()
	defer stopManager(t, manager)
	watch, _ := collect(t, manager, root, "watched", true)
	if err := os.RemoveAll(directory); err != nil {
		t.Fatal(err)
	}
	select {
	case <-watch.Done():
	case <-time.After(3 * time.Second):
		t.Fatal("watch survived the removal of its directory")
	}
	manager.mu.Lock()
	defer manager.mu.Unlock()
	if len(manager.directories) != 0 || manager.held != 0 {
		t.Fatalf("directory accounting survived: %v", manager.directories)
	}
}

func TestRecursiveWatchDirectoryLimit(t *testing.T) {
	root := t.TempDir()
	for index := range maxWatchDirectories {
		if err := os.Mkdir(filepath.Join(root, fmt.Sprintf("d%04d", index)), 0700); err != nil {
			t.Fatal(err)
		}
	}
	manager := NewManager()
	defer stopManager(t, manager)
	_, err := manager.Start(t.Context(), "owner", "project:root", root, ".", true, func(Event) error { return nil })
	var typed apierror.Error
	if !errors.As(err, &typed) || typed.Kind() != apierror.RateLimited {
		t.Fatalf("want RateLimited, got %v", err)
	}
	manager.mu.Lock()
	defer manager.mu.Unlock()
	if len(manager.directories) != 0 || manager.held != 0 || len(manager.active) != 0 {
		t.Fatal("refused recursive watch kept native watches")
	}
}

func TestSharedDirectoriesHoldOneNativeWatch(t *testing.T) {
	root := t.TempDir()
	manager := NewManager()
	defer stopManager(t, manager)
	first, _ := collect(t, manager, root, ".", true)
	_, events := collect(t, manager, root, ".", false)
	await(t, events, rescan("."))
	first.Close()
	<-first.Done()
	write(t, filepath.Join(root, "after.txt"))
	await(t, events, change("after.txt"))
}

func TestWatchRejectsTraversalAndSymlinkEscape(t *testing.T) {
	root, outside := t.TempDir(), t.TempDir()
	if err := os.Symlink(outside, filepath.Join(root, "escape")); err != nil {
		t.Fatal(err)
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
	_, events := collect(t, manager, root, "literal...", false)
	await(t, events, rescan("literal..."))
	write(t, filepath.Join(directory, "file.txt"))
	await(t, events, change("literal.../file.txt"))
}

func TestOwnerCancellationReleasesWatch(t *testing.T) {
	manager := NewManager()
	defer stopManager(t, manager)
	ctx, cancel := context.WithCancel(context.Background())
	watch, err := manager.Start(ctx, "owner", "project:root", t.TempDir(), ".", true, func(Event) error { return nil })
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
	if len(manager.active) != 0 || len(manager.owners) != 0 || len(manager.directories) != 0 {
		t.Fatal("watch accounting survived cancellation")
	}
}

func TestRefusingReceiverEndsWatch(t *testing.T) {
	manager := NewManager()
	defer stopManager(t, manager)
	root := t.TempDir()
	watch, err := manager.Start(t.Context(), "owner", "project:root", root, ".", false, func(event Event) error {
		if event.Kind == EventChange {
			return errors.New("receiver gone")
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(root, "file.txt"))
	select {
	case <-watch.Done():
	case <-time.After(3 * time.Second):
		t.Fatal("watch survived a refusing receiver")
	}
}

func TestWatchQuotaAndManagerShutdown(t *testing.T) {
	manager := NewManager()
	root := t.TempDir()
	for range maxOwnerWatches {
		if _, err := manager.Start(context.Background(), "owner", "project:root", root, ".", false, func(Event) error { return nil }); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := manager.Start(context.Background(), "owner", "project:root", root, ".", false, func(Event) error { return nil }); err == nil {
		t.Fatal("owner quota was not enforced")
	}
	stopManager(t, manager)
	if _, err := manager.Start(context.Background(), "new-owner", "project:root", root, ".", false, func(Event) error { return nil }); err == nil {
		t.Fatal("stopped service accepted watch")
	}
}

func TestWatchFailuresCarryKindsWithoutHostPaths(t *testing.T) {
	root, outside := t.TempDir(), t.TempDir()
	if err := os.Symlink(outside, filepath.Join(root, "escape")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "file"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(root, "sealed"), 0); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "tree", "sealed"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(filepath.Join(root, "tree", "sealed"), 0); err != nil {
		t.Fatal(err)
	}
	type start struct {
		relative  string
		recursive bool
	}
	cases := map[start]apierror.Kind{
		{"../outside", false}: apierror.Invalid,
		{"escape", false}:     apierror.PermissionDenied,
		{"missing", false}:    apierror.NotFound,
		{"file", false}:       apierror.Invalid,
	}
	if os.Geteuid() != 0 {
		cases[start{"sealed", false}] = apierror.PermissionDenied
		cases[start{"tree", true}] = apierror.PermissionDenied
	}
	manager := NewManager()
	defer stopManager(t, manager)
	run := func(owner, relative string, recursive bool) error {
		_, err := manager.Start(context.Background(), owner, "project:root", root, relative, recursive, func(Event) error { return nil })
		return err
	}
	for given, kind := range cases {
		err := run("owner", given.relative, given.recursive)
		var typed apierror.Error
		if !errors.As(err, &typed) || typed.Kind() != kind || typed.Retryable() != apierror.False {
			t.Fatalf("%+v: want %s, got %v", given, kind, err)
		}
		if strings.Contains(err.Error(), root) || strings.Contains(err.Error(), outside) {
			t.Fatalf("%+v: error reveals a host path: %v", given, err)
		}
	}
	for range maxOwnerWatches {
		if err := run("owner", ".", false); err != nil {
			t.Fatal(err)
		}
	}
	var typed apierror.Error
	if err := run("owner", ".", false); !errors.As(err, &typed) || typed.Kind() != apierror.RateLimited {
		t.Fatalf("quota: want RateLimited, got %v", err)
	}
}
