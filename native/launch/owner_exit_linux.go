//go:build meshclient && physicalclient && linux

// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"errors"
	"fmt"
	"time"

	"golang.org/x/sys/unix"
)

type linuxOwnerExit struct {
	pid int
	fd  int
}

func holdOwnerProcessExit(pid int) (ownerExitObserver, error) {
	if pid <= 0 {
		return nil, errors.New("owner descriptor has no valid process ID")
	}
	fd, err := unix.PidfdOpen(pid, 0)
	if err != nil {
		return nil, fmt.Errorf("hold owner process: %w", err)
	}
	return &linuxOwnerExit{pid: pid, fd: fd}, nil
}

func (o *linuxOwnerExit) wait(ctx context.Context) error {
	deadline := time.Now().Add(stopTimeout)
	poll := []unix.PollFd{{Fd: int32(o.fd), Events: unix.POLLIN}}
	for {
		if err := ctx.Err(); err != nil {
			return fmt.Errorf("waiting for Bee owner process PID %d: %w", o.pid, err)
		}
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return fmt.Errorf("Bee owner process PID %d is still running after %s", o.pid, stopTimeout)
		}
		interval := min(remaining, waitPollInterval)
		poll[0].Revents = 0
		_, err := unix.Poll(poll, int((interval+time.Millisecond-1)/time.Millisecond))
		if errors.Is(err, unix.EINTR) {
			continue
		}
		if err != nil {
			return fmt.Errorf("observe Bee owner process PID %d: %w", o.pid, err)
		}
		if poll[0].Revents != 0 {
			return nil
		}
	}
}

func (o *linuxOwnerExit) close() error {
	if o.fd < 0 {
		return nil
	}
	err := unix.Close(o.fd)
	o.fd = -1
	return err
}
