//go:build meshclient && physicalclient && !linux && !darwin && !windows

// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"errors"
	"fmt"
	"syscall"
	"time"
)

type pollingOwnerExit struct{ pid int }

func holdOwnerProcessExit(pid int) (ownerExitObserver, error) {
	if pid <= 0 {
		return nil, errors.New("owner descriptor has no valid process ID")
	}
	if err := syscall.Kill(pid, 0); errors.Is(err, syscall.ESRCH) {
		return nil, fmt.Errorf("owner process PID %d has already exited", pid)
	} else if err != nil && !errors.Is(err, syscall.EPERM) {
		return nil, fmt.Errorf("inspect owner process PID %d: %w", pid, err)
	}
	return pollingOwnerExit{pid: pid}, nil
}

func (o pollingOwnerExit) wait(ctx context.Context) error {
	deadline := time.Now().Add(stopTimeout)
	for {
		if err := ctx.Err(); err != nil {
			return fmt.Errorf("waiting for Bee owner process PID %d: %w", o.pid, err)
		}
		if err := syscall.Kill(o.pid, 0); errors.Is(err, syscall.ESRCH) {
			return nil
		} else if err != nil && !errors.Is(err, syscall.EPERM) {
			return fmt.Errorf("observe Bee owner process PID %d: %w", o.pid, err)
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("Bee owner process PID %d is still running after %s", o.pid, stopTimeout)
		}
		select {
		case <-ctx.Done():
		case <-time.After(waitPollInterval):
		}
	}
}

func (pollingOwnerExit) close() error { return nil }
