//go:build meshclient && physicalclient && windows

// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"errors"
	"fmt"
	"time"

	"golang.org/x/sys/windows"
)

type windowsOwnerExit struct {
	pid    int
	handle windows.Handle
}

func holdOwnerProcessExit(pid int) (ownerExitObserver, error) {
	if pid <= 0 || uint64(pid) > uint64(^uint32(0)) {
		return nil, errors.New("owner descriptor has no valid process ID")
	}
	handle, err := windows.OpenProcess(windows.SYNCHRONIZE, false, uint32(pid))
	if err != nil {
		return nil, fmt.Errorf("hold owner process: %w", err)
	}
	return &windowsOwnerExit{pid: pid, handle: handle}, nil
}

func (o *windowsOwnerExit) wait(ctx context.Context) error {
	deadline := time.Now().Add(stopTimeout)
	for {
		if err := ctx.Err(); err != nil {
			return fmt.Errorf("waiting for Bee owner process PID %d: %w", o.pid, err)
		}
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return fmt.Errorf("Bee owner process PID %d is still running after %s", o.pid, stopTimeout)
		}
		interval := min(remaining, waitPollInterval)
		milliseconds := uint32((interval + time.Millisecond - 1) / time.Millisecond)
		result, err := windows.WaitForSingleObject(o.handle, milliseconds)
		if err != nil {
			return fmt.Errorf("observe Bee owner process PID %d: %w", o.pid, err)
		}
		if result == windows.WAIT_OBJECT_0 {
			return nil
		}
		if result != uint32(windows.WAIT_TIMEOUT) {
			return fmt.Errorf("observe Bee owner process PID %d: unexpected wait result %#x", o.pid, result)
		}
	}
}

func (o *windowsOwnerExit) close() error {
	if o.handle == 0 {
		return nil
	}
	err := windows.CloseHandle(o.handle)
	o.handle = 0
	return err
}
