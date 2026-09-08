// SPDX-License-Identifier: MIT

package ioevents

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/syncthing/notify"
)

const (
	maxWatches      = 128
	maxOwnerWatches = 32
	eventBuffer     = 128
)

// Event is a filesystem change hint. Rescan events require reconciliation of
// the watched directory because the operating system may coalesce or lose hints.
type Event struct {
	Kind      string
	Resource  string
	Path      string
	Operation string
}

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
	if manager.closed || len(manager.active) >= maxWatches || manager.owners[owner] >= maxOwnerWatches {
		manager.mu.Unlock()
		cancel()
		return nil, fmt.Errorf("watch service stopped or watch limit reached")
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
	if err := notify.Watch(directory, raw, notify.All); err != nil {
		release()
		return nil, err
	}
	go func() {
		defer release()
		defer notify.Stop(raw)
		timer := time.NewTicker(manager.rescanInterval)
		defer timer.Stop()
		rescan := Event{Kind: "rescan", Resource: resource, Path: filepath.ToSlash(filepath.Clean(relative))}
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
			case rawEvent := <-raw:
				if rawEvent == nil {
					continue
				}
				relativePath, err := filepath.Rel(root, rawEvent.Path())
				if err != nil || !filepath.IsLocal(relativePath) {
					continue
				}
				event := Event{Kind: "change", Resource: resource, Path: filepath.ToSlash(relativePath), Operation: eventOperation(rawEvent.Event())}
				if err := emit(event); err != nil {
					return
				}
			}
		}
	}()
	return watch, nil
}

func containedDirectory(root, relative string) (string, string, error) {
	if !filepath.IsAbs(root) || !filepath.IsLocal(relative) {
		return "", "", fmt.Errorf("watch requires a host root and a contained relative path")
	}
	canonicalRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", "", err
	}
	target, err := filepath.EvalSymlinks(filepath.Join(canonicalRoot, relative))
	if err != nil {
		return "", "", err
	}
	within, err := filepath.Rel(canonicalRoot, target)
	if err != nil || !filepath.IsLocal(within) {
		return "", "", fmt.Errorf("watch path escapes filesystem root")
	}
	info, err := os.Stat(target)
	if err != nil {
		return "", "", err
	}
	if !info.IsDir() {
		return "", "", fmt.Errorf("watch the containing directory of a file")
	}
	return target, canonicalRoot, nil
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
