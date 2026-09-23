// SPDX-License-Identifier: MIT

package privatefile

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

var ErrLockBusy = errors.New("privatefile: lock is busy")
var errLockBusy = ErrLockBusy

// TryLock acquires one protected stable lock file without waiting. The context
// controls acquisition only. The caller holds the OS lock until it releases the
// returned handle or exits; no clock, heartbeat or goroutine renews it.
// Never unlink the lock file, including after release.
func TryLock(ctx context.Context, directory, name string) (func() error, error) {
	if ctx == nil {
		return nil, errors.New("privatefile: context is required")
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if strings.TrimSpace(directory) == "" {
		return nil, ErrInvalidName
	}
	if err := validateBasename(name); err != nil {
		return nil, err
	}
	directory = filepath.Clean(directory)
	if err := ensurePrivateDir(directory); err != nil {
		return nil, err
	}
	if err := checkDirPermissions(directory); err != nil {
		return nil, err
	}
	return acquireLockMode(ctx, filepath.Join(directory, name), false)
}

// acquireLock locks lockPath using an OS-backed advisory file lock.
// It contends on a stable inode and NEVER unlinks the lock file.
// Context cancellation and deadlines are supported via bounded polling without
// spawning background goroutines. Any acquired lock is released immediately upon cancellation.
func acquireLock(ctx context.Context, lockPath string) (func() error, error) {
	return acquireLockMode(ctx, lockPath, true)
}

func acquireLockMode(ctx context.Context, lockPath string, wait bool) (func() error, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	// Validate existing lock file before opening to avoid symlinks and foreign files.
	fi, err := os.Lstat(lockPath)
	if err == nil {
		if fi.Mode()&os.ModeSymlink != 0 {
			return nil, fmt.Errorf("lock file %q is a symlink", lockPath)
		}
		if !fi.Mode().IsRegular() {
			return nil, fmt.Errorf("lock file %q is not a regular file (mode: %s)", lockPath, fi.Mode())
		}
		if err := checkFilePathPermissions(lockPath); err != nil {
			return nil, fmt.Errorf("insecure lock file %q: %w", lockPath, err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("stat lock file: %w", err)
	}

	// Open lock file avoiding symlink traversal.
	file, err := openLockFile(lockPath)
	if err != nil {
		return nil, fmt.Errorf("open lock file: %w", err)
	}

	// Double check regular file on descriptor.
	st, err := file.Stat()
	if err != nil {
		_ = file.Close()
		return nil, fmt.Errorf("stat opened lock file: %w", err)
	}
	if !st.Mode().IsRegular() {
		_ = file.Close()
		return nil, fmt.Errorf("opened lock file %q is not regular (mode: %s)", lockPath, st.Mode())
	}

	// Creation establishes permissions; validation never repairs an existing lock.
	if err := checkFilePermissions(st); err != nil {
		_ = file.Close()
		return nil, fmt.Errorf("opened lock file permissions: %w", err)
	}
	if err := checkFilePathPermissions(lockPath); err != nil {
		_ = file.Close()
		return nil, fmt.Errorf("insecure lock file %q: %w", lockPath, err)
	}

	// Attempt non-blocking lock immediately.
	unlock, err := tryLockFile(file)
	if err == nil {
		if err := ctx.Err(); err != nil {
			_ = unlock()
			_ = file.Close()
			return nil, err
		}
		return makeUnlockFn(file, unlock), nil
	}
	if !errors.Is(err, errLockBusy) {
		_ = file.Close()
		return nil, fmt.Errorf("lock file: %w", err)
	}

	if !wait {
		_ = file.Close()
		return nil, ErrLockBusy
	}

	// Lock is held by another process or thread. Wait with context deadline/cancel.
	// We run directly in caller's goroutine using a ticker to avoid leaking goroutines.
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			_ = file.Close()
			return nil, ctx.Err()
		case <-ticker.C:
			unlock, err := tryLockFile(file)
			if err == nil {
				if err := ctx.Err(); err != nil {
					_ = unlock()
					_ = file.Close()
					return nil, err
				}
				return makeUnlockFn(file, unlock), nil
			}
			if !errors.Is(err, errLockBusy) {
				_ = file.Close()
				return nil, fmt.Errorf("lock file: %w", err)
			}
		}
	}
}

func makeUnlockFn(file *os.File, unlock func() error) func() error {
	var once sync.Once
	var unlockErr error
	return func() error {
		once.Do(func() {
			var errs []error
			if unlock != nil {
				if err := unlock(); err != nil {
					errs = append(errs, err)
				}
			}
			if file != nil {
				if err := file.Close(); err != nil {
					errs = append(errs, err)
				}
			}
			unlockErr = errors.Join(errs...)
		})
		return unlockErr
	}
}
