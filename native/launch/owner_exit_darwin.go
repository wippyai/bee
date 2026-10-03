//go:build meshclient && physicalclient && darwin

// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"errors"
	"fmt"
	"os"
	"time"

	"golang.org/x/sys/unix"
)

type darwinOwnerExit struct {
	pid int
	kq  int
}

func holdOwnerProcessExit(pid int) (ownerExitObserver, error) {
	if pid <= 0 {
		return nil, errors.New("owner descriptor has no valid process ID")
	}
	kq, err := unix.Kqueue()
	if err != nil {
		return nil, fmt.Errorf("open owner exit observer: %w", err)
	}
	change := unix.Kevent_t{Fflags: unix.NOTE_EXIT}
	unix.SetKevent(&change, pid, unix.EVFILT_PROC, unix.EV_ADD|unix.EV_ONESHOT)
	if _, err := unix.Kevent(kq, []unix.Kevent_t{change}, nil, nil); err != nil {
		_ = unix.Close(kq)
		if errors.Is(err, unix.ESRCH) {
			return nil, os.ErrProcessDone
		}
		return nil, fmt.Errorf("hold owner process PID %d: %w", pid, err)
	}
	return &darwinOwnerExit{pid: pid, kq: kq}, nil
}

func (o *darwinOwnerExit) wait(ctx context.Context) error {
	deadline := time.Now().Add(stopTimeout)
	events := make([]unix.Kevent_t, 1)
	for {
		if err := ctx.Err(); err != nil {
			return fmt.Errorf("waiting for Bee owner process PID %d: %w", o.pid, err)
		}
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return fmt.Errorf("Bee owner process PID %d is still running after %s", o.pid, stopTimeout)
		}
		interval := min(remaining, waitPollInterval)
		timeout := unix.NsecToTimespec(interval.Nanoseconds())
		n, err := unix.Kevent(o.kq, nil, events, &timeout)
		if errors.Is(err, unix.EINTR) {
			continue
		}
		if err != nil {
			return fmt.Errorf("observe Bee owner process PID %d: %w", o.pid, err)
		}
		if n != 0 {
			return nil
		}
	}
}

func (o *darwinOwnerExit) close() error {
	if o.kq < 0 {
		return nil
	}
	err := unix.Close(o.kq)
	o.kq = -1
	return err
}
