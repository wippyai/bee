// SPDX-License-Identifier: MIT

package ioevents

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/fsnotify/fsnotify"
	apierror "github.com/wippyai/runtime/api/error"
)

const (
	maxWatches      = 128
	maxOwnerWatches = 32
	// maxDirectories bounds the directories all watches follow together;
	// maxWatchDirectories bounds one recursive watch.
	maxDirectories      = 8192
	maxWatchDirectories = 1024
	eventBuffer         = 128
)

// Event is a filesystem change hint. A rescan event names a directory whose
// notices may have been lost; the consumer lists it again.
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

// Manager owns native watches independently of any presentation process. One
// backend watcher serves every watch; a directory several watches follow
// holds one native watch.
type Manager struct {
	mu          sync.Mutex
	backend     *fsnotify.Watcher
	dispatching chan struct{}
	directories map[string]int
	held        int
	active      map[*Watch]struct{}
	owners      map[string]int
	closed      bool
	watches     sync.WaitGroup
}

// Watch is owned by one runtime process subscription. It observes one
// directory under root and, when recursive, every directory below it.
type Watch struct {
	owner, resource string
	root, directory string
	recursive       bool
	followed        map[string]struct{}
	emit            func(Event) error
	ended           bool
	cancel          context.CancelFunc
	done            chan struct{}
}

func NewManager() *Manager {
	return &Manager{directories: make(map[string]int), active: make(map[*Watch]struct{}), owners: make(map[string]int)}
}

// Close cancels the watch; Done closes once its native watches are released.
func (watch *Watch) Close()                { watch.cancel() }
func (watch *Watch) Done() <-chan struct{} { return watch.done }

// Start watches one directory under root and, when recursive, every directory
// below it, including directories created later. The first event is a rescan
// of the watched directory. Call it outside the Lua scheduler step because
// installing native watches may block.
func (manager *Manager) Start(ctx context.Context, owner, resource, root, relative string, recursive bool, emit func(Event) error) (*Watch, error) {
	if ctx == nil || owner == "" || resource == "" || emit == nil {
		return nil, fmt.Errorf("watch context, owner, resource and receiver are required")
	}
	directory, root, err := containedDirectory(root, relative)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(ctx)
	watch := &Watch{owner: owner, resource: resource, root: root, directory: directory, recursive: recursive,
		followed: make(map[string]struct{}), emit: emit, cancel: cancel, done: make(chan struct{})}
	manager.mu.Lock()
	defer manager.mu.Unlock()
	if manager.closed {
		cancel()
		return nil, apierror.New(apierror.Unavailable, "watch service stopped").WithRetryable(apierror.False)
	}
	if len(manager.active) >= maxWatches || manager.owners[owner] >= maxOwnerWatches {
		cancel()
		return nil, apierror.New(apierror.RateLimited, "watch limit reached").WithRetryable(apierror.False)
	}
	if err := ctx.Err(); err != nil {
		cancel()
		return nil, err
	}
	if err := manager.openBackend(); err != nil {
		cancel()
		return nil, err
	}
	if err := manager.follow(watch, directory); err != nil {
		manager.unfollow(watch, directory)
		cancel()
		return nil, err
	}
	manager.active[watch] = struct{}{}
	manager.owners[owner]++
	manager.watches.Add(1)
	// The first rescan follows the installed native watches, so a listing
	// made on it misses no change.
	manager.deliver(watch, watch.rescan(directory))
	go func() {
		<-ctx.Done()
		manager.release(watch)
	}()
	return watch, nil
}

func (manager *Manager) openBackend() error {
	if manager.backend != nil {
		return nil
	}
	backend, err := fsnotify.NewWatcher()
	if err != nil {
		return apierror.New(apierror.Unavailable, "native watch service cannot start").WithRetryable(apierror.False)
	}
	manager.backend = backend
	manager.dispatching = make(chan struct{})
	go manager.dispatch(backend, manager.dispatching)
	return nil
}

// follow installs native watches on directory and, for a recursive watch,
// on every directory below it. Symbolic links are never followed, so a
// recursive watch stays below the directory it started from.
func (manager *Manager) follow(watch *Watch, directory string) error {
	if !watch.recursive {
		return manager.hold(watch, directory)
	}
	return filepath.WalkDir(directory, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) && path != directory {
				return nil
			}
			return pathError(watch.relative(path), err)
		}
		if !entry.IsDir() {
			return nil
		}
		return manager.hold(watch, path)
	})
}

func (manager *Manager) hold(watch *Watch, directory string) error {
	if _, ok := watch.followed[directory]; ok {
		return nil
	}
	if len(watch.followed) >= maxWatchDirectories || manager.held >= maxDirectories {
		return apierror.New(apierror.RateLimited, "watch directory limit reached: "+watch.relative(directory)).WithRetryable(apierror.False)
	}
	if manager.directories[directory] == 0 {
		if err := manager.backend.Add(directory); err != nil {
			// A directory removed before it is followed leaves nothing to
			// observe; its parent reports the removal.
			if errors.Is(err, fs.ErrNotExist) && directory != watch.directory {
				return nil
			}
			return pathError(watch.relative(directory), err)
		}
	}
	manager.directories[directory]++
	manager.held++
	watch.followed[directory] = struct{}{}
	return nil
}

// unfollow releases what watch follows at and below directory.
func (manager *Manager) unfollow(watch *Watch, directory string) {
	for path := range watch.followed {
		if path != directory && !strings.HasPrefix(path, directory+string(os.PathSeparator)) {
			continue
		}
		delete(watch.followed, path)
		manager.held--
		manager.directories[path]--
		if manager.directories[path] > 0 {
			continue
		}
		delete(manager.directories, path)
		// The kernel drops the native watch of a removed or moved directory
		// itself, which the backend then reports as nonexistent.
		if err := manager.backend.Remove(path); err != nil && !errors.Is(err, fsnotify.ErrNonExistentWatch) {
			manager.end(watch)
		}
	}
}

func (manager *Manager) release(watch *Watch) {
	manager.mu.Lock()
	watch.ended = true
	manager.unfollow(watch, watch.directory)
	delete(manager.active, watch)
	manager.owners[watch.owner]--
	if manager.owners[watch.owner] == 0 {
		delete(manager.owners, watch.owner)
	}
	manager.mu.Unlock()
	close(watch.done)
	manager.watches.Done()
}

// end stops a watch whose notices can no longer be complete. Its owner sees
// the watch close and opens it again.
func (manager *Manager) end(watch *Watch) {
	watch.ended = true
	watch.cancel()
}

// deliver hands one event to the watch's receiver; a receiver that refuses
// it ends the watch.
func (manager *Manager) deliver(watch *Watch, event Event) {
	if watch.ended {
		return
	}
	if err := watch.emit(event); err != nil {
		manager.end(watch)
	}
}

// dispatch routes backend notices. A backend overflow means notices were
// lost, so every watch rescans its directory; any other backend failure ends
// every watch.
func (manager *Manager) dispatch(backend *fsnotify.Watcher, done chan struct{}) {
	defer close(done)
	for {
		select {
		case event, ok := <-backend.Events:
			if !ok {
				return
			}
			manager.mu.Lock()
			for watch := range manager.active {
				manager.observe(watch, event)
			}
			manager.mu.Unlock()
		case err, ok := <-backend.Errors:
			if !ok {
				return
			}
			manager.mu.Lock()
			for watch := range manager.active {
				if errors.Is(err, fsnotify.ErrEventOverflow) {
					manager.deliver(watch, watch.rescan(watch.directory))
				} else {
					manager.end(watch)
				}
			}
			manager.mu.Unlock()
		}
	}
}

// observe routes one backend event to watch. Called with the manager lock.
func (manager *Manager) observe(watch *Watch, event fsnotify.Event) {
	if watch.ended {
		return
	}
	name := filepath.Clean(event.Name)
	if name == watch.directory && event.Op&(fsnotify.Remove|fsnotify.Rename) != 0 {
		manager.end(watch)
		return
	}
	if _, covered := watch.followed[filepath.Dir(name)]; !covered && name != watch.directory {
		return
	}
	manager.deliver(watch, Event{Kind: EventChange, Resource: watch.resource, Path: watch.relative(name), Operation: eventOperation(event.Op)})
	if !watch.recursive || name == watch.directory {
		return
	}
	if event.Op&(fsnotify.Remove|fsnotify.Rename) != 0 {
		manager.unfollow(watch, name)
	}
	if event.Op&fsnotify.Create == 0 {
		return
	}
	if _, followed := watch.followed[name]; followed {
		return
	}
	info, err := os.Lstat(name)
	if err != nil || !info.IsDir() {
		return
	}
	// A new directory can gain entries before its native watch exists, so it
	// is listed again once followed.
	if err := manager.follow(watch, name); err != nil {
		manager.end(watch)
		return
	}
	manager.deliver(watch, watch.rescan(name))
}

func (watch *Watch) relative(path string) string {
	relative, err := filepath.Rel(watch.root, path)
	if err != nil {
		return "."
	}
	return filepath.ToSlash(relative)
}

func (watch *Watch) rescan(directory string) Event {
	return Event{Kind: EventRescan, Resource: watch.resource, Path: watch.relative(directory)}
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
		return apierror.New(apierror.Unavailable, "native watch cannot start: "+name).WithRetryable(apierror.False)
	}
}

// Stop ends every watch, waits for their release and closes the backend.
func (manager *Manager) Stop(ctx context.Context) error {
	manager.mu.Lock()
	manager.closed = true
	for watch := range manager.active {
		watch.Close()
	}
	manager.mu.Unlock()
	released := make(chan struct{})
	go func() { manager.watches.Wait(); close(released) }()
	select {
	case <-released:
	case <-ctx.Done():
		return errors.Join(fmt.Errorf("waiting for native watches to close"), ctx.Err())
	}
	manager.mu.Lock()
	backend, dispatching := manager.backend, manager.dispatching
	manager.backend = nil
	manager.mu.Unlock()
	if backend == nil {
		return nil
	}
	if err := backend.Close(); err != nil {
		return err
	}
	select {
	case <-dispatching:
		return nil
	case <-ctx.Done():
		return errors.Join(fmt.Errorf("waiting for the native watch backend to close"), ctx.Err())
	}
}

func eventOperation(op fsnotify.Op) string {
	switch {
	case op&fsnotify.Create != 0:
		return "create"
	case op&fsnotify.Remove != 0:
		return "remove"
	case op&fsnotify.Rename != 0:
		return "rename"
	case op&fsnotify.Write != 0:
		return "write"
	default:
		return "other"
	}
}
