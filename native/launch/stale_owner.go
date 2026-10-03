// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/wippyai/bee/native/hive/rendezvous"
	"github.com/wippyai/bee/native/internal/privatefile"
)

func clearStaleOwner(ctx context.Context, state string, hold func(int) (ownerExitObserver, error)) (cleared bool, result error) {
	directory := filepath.Join(state, rendezvous.DirectoryName)
	store, err := rendezvous.New(directory)
	if err != nil {
		return false, err
	}
	record, err := store.Read(ctx)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	// Hold the runtime's stable state lock throughout the liveness check and
	// deletion. A new owner cannot start and publish between them.
	release, err := privatefile.TryLock(ctx, state, "lock")
	if err != nil {
		return false, fmt.Errorf("cannot clear stale Bee owner while state is held: %w", err)
	}
	defer func() { result = errors.Join(result, release()) }()
	observer, err := hold(record.OwnerPID)
	if err == nil {
		return false, errors.Join(fmt.Errorf("recorded Bee owner PID %d is still live; stale record retained", record.OwnerPID), observer.close())
	}
	if !errors.Is(err, os.ErrProcessDone) {
		return false, err
	}
	if err := store.Clear(ctx, record); err != nil {
		return false, err
	}
	return true, nil
}
