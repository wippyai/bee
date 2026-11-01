// SPDX-License-Identifier: MIT

package ioevents

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/syncthing/notify"
	apierror "github.com/wippyai/runtime/api/error"
)

const (
	maxWatches      = 128
	maxOwnerWatches = 32
	eventBuffer     = 128
)

// Event is a filesystem change hint. Rescan events require reconciliation of
// the watched directory because the operating system may coalesce or lose hints.
type Event struct {
	Kind      EventKind
	Resource  string
	Path      string
	Operation string
}

// EventKind is one filesystem notification the native service emits.
type EventKind string

const (
	EventChange EventKind = "change"
	EventRescan EventKind = "rescan"
)

// Manager owns native watches independently of any presentation process.
type Manager struct {
	mu             sync.Mutex
	active         map[*Watch]string
	owners         map[string]int
	closed         bool
	wait           sync.WaitGroup
	rescanInterval time.Duration
}

// Watch is owned by one runtime process subscription.
type Watch struct {
	cancel context.CancelFunc
	done   chan struct{}
}

func NewManager() *Manager {
	return &Manager{active: make(map[*Watch]string), owners: make(map[string]int), rescanInterval: 5 * time.Second}
}

func (watch *Watch) Close()                { watch.cancel() }
func (watch *Watch) Done() <-chan struct{} { return watch.done }

// Start watches one directory, without following child directories. Call it
// outside the Lua scheduler step because installing an OS watch may block.
func (manager *Manager) Start(ctx context.Context, owner, resource, root, relative string, emit func(Event) error) (*Watch, error) {
	if ctx == nil || owner == "" || resource == "" || emit == nil {
		return nil, fmt.Errorf("watch context, owner, resource and receiver are required")
	}
	ctx, cancel := context.WithCancel(ctx)
	watch := &Watch{cancel: cancel, done: make(chan struct{})}
	manager.mu.Lock()
	if manager.closed {
		manager.mu.Unlock()
		cancel()
		return nil, apierror.New(apierror.Unavailable, "watch service stopped").WithRetryable(apierror.False)
	}
	if len(manager.active) >= maxWatches || manager.owners[owner] >= maxOwnerWatches {
		manager.mu.Unlock()
		cancel()
		return nil, apierror.New(apierror.RateLimited, "watch limit reached").WithRetryable(apierror.False)
	}
	manager.active[watch] = owner
	manager.owners[owner]++
	manager.wait.Add(1)
	manager.mu.Unlock()
	release := func() {
		cancel()
		manager.mu.Lock()
		delete(manager.active, watch)
		manager.owners[owner]--
		if manager.owners[owner] == 0 {
			delete(manager.owners, owner)
		}
		manager.mu.Unlock()
		close(watch.done)
		manager.wait.Done()
	}
	directory, root, err := containedDirectory(root, relative)
	if err != nil {
		release()
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		release()
		return nil, err
	}
	raw := make(chan notify.EventInfo, eventBuffer)
	// The backend interprets a trailing "..." as a recursive watch request.
	// Append a literal directory separator so valid names retain their meaning.
	if err := notify.Watch(directory+string(os.PathSeparator), raw, notify.All); err != nil {
		release()
		if errors.Is(err, fs.ErrPermission) {
			return nil, pathError(relative, err)
		}
		return nil, apierror.New(apierror.Unavailable, "native watch cannot start: "+relative).WithRetryable(apierror.False)
	}
	go func() {
		defer release()
		defer notify.Stop(raw)
		watchEvents(ctx, raw, manager.rescanInterval, root,
			Event{Kind: EventRescan, Resource: resource, Path: filepath.ToSlash(filepath.Clean(relative))}, emit)
	}()
	return watch, nil
}

func watchEvents(ctx context.Context, raw <-chan notify.EventInfo, rescanInterval time.Duration, root string, rescan Event, emit func(Event) error) {
	timer := time.NewTicker(rescanInterval)
	defer timer.Stop()
	if err := emit(rescan); err != nil {
		return
	}
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
			if err := emit(rescan); err != nil {
				return
			}
		case rawEvent, ok := <-raw:
			if !ok {
				return
			}
			if rawEvent == nil {
				continue
			}
			relativePath, err := filepath.Rel(root, rawEvent.Path())
			if err != nil || !filepath.IsLocal(relativePath) {
				continue
			}
			event := Event{Kind: EventChange, Resource: rescan.Resource, Path: filepath.ToSlash(relativePath), Operation: eventOperation(rawEvent.Event())}
			if err := emit(event); err != nil {
				return
			}
		}
	}
}

// containedDirectory resolves relative under root. Its errors name no host
// path: callers see only the paths of their own filesystem resource.
func containedDirectory(root, relative string) (string, string, error) {
	if !filepath.IsAbs(root) || !filepath.IsLocal(relative) {
		return "", "", apierror.New(apierror.Invalid, "watch requires a contained relative path").WithRetryable(apierror.False)
	}
	canonicalRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", "", pathError("filesystem root", err)
	}
	target, err := filepath.EvalSymlinks(filepath.Join(canonicalRoot, relative))
	if err != nil {
		return "", "", pathError(relative, err)
	}
	within, err := filepath.Rel(canonicalRoot, target)
	if err != nil || !filepath.IsLocal(within) {
		return "", "", apierror.New(apierror.PermissionDenied, "watch path escapes filesystem root: "+relative).WithRetryable(apierror.False)
	}
	info, err := os.Stat(target)
	if err != nil {
		return "", "", pathError(relative, err)
	}
	if !info.IsDir() {
		return "", "", apierror.New(apierror.Invalid, "watch the containing directory of a file: "+relative).WithRetryable(apierror.False)
	}
	return target, canonicalRoot, nil
}

func pathError(name string, err error) error {
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return apierror.New(apierror.NotFound, "watch path not found: "+name).WithRetryable(apierror.False)
	case errors.Is(err, fs.ErrPermission):
		return apierror.New(apierror.PermissionDenied, "watch path is not readable: "+name).WithRetryable(apierror.False)
	default:
		return apierror.New(apierror.Invalid, "watch path cannot be resolved: "+name).WithRetryable(apierror.False)
	}
}

func (manager *Manager) Stop(ctx context.Context) error {
	manager.mu.Lock()
	manager.closed = true
	for watch := range manager.active {
		watch.Close()
	}
	manager.mu.Unlock()
	done := make(chan struct{})
	go func() { manager.wait.Wait(); close(done) }()
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return errors.Join(fmt.Errorf("waiting for native watches to close"), ctx.Err())
	}
}

func eventOperation(event notify.Event) string {
	switch {
	case event&notify.Create != 0:
		return "create"
	case event&notify.Remove != 0:
		return "remove"
	case event&notify.Rename != 0:
		return "rename"
	case event&notify.Write != 0:
		return "write"
	default:
		return "other"
	}
}
