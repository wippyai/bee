// SPDX-License-Identifier: MIT

// Package processes reads the process table and holds exit-observing process
// handles for acceptance fixtures on Linux and macOS.
//
// A Handle names one process for its lifetime: a pidfd on Linux and a kqueue
// NOTE_EXIT registration on macOS. Callers open a handle first and then
// confirm the process identity, so a PID recycled after a table scan is
// rejected before any signal is sent.
package processes

import (
	"errors"
	"sort"
	"time"

	"golang.org/x/sys/unix"
)

// Stop asks the held process to terminate, escalates to SIGKILL after grace,
// and requires the exit to be observed.
func (h *Handle) Stop(grace time.Duration) error {
	if h.Exited(0) {
		return nil
	}
	if err := h.Signal(unix.SIGTERM); err != nil {
		return err
	}
	if h.Exited(grace) {
		return nil
	}
	return h.Kill()
}

// Kill sends SIGKILL and requires the exit to be observed.
func (h *Handle) Kill() error {
	if h.Exited(0) {
		return nil
	}
	if err := h.Signal(unix.SIGKILL); err != nil {
		return err
	}
	if !h.Exited(5 * time.Second) {
		return errors.New("process did not exit after SIGKILL")
	}
	return nil
}

// Hold opens a handle for pid and returns it only when matches accepts the
// process arguments read after the handle exists.
func Hold(pid int, matches func(args []string) bool) (*Handle, error) {
	handle, err := Open(pid)
	if err != nil {
		return nil, err
	}
	args, err := Args(pid)
	if err != nil {
		_ = handle.Close()
		return nil, err
	}
	if handle.Exited(0) || !matches(args) {
		_ = handle.Close()
		return nil, errors.New("process identity changed before the handle was held")
	}
	return handle, nil
}

// Find returns the sorted PIDs whose arguments matches accepts.
func Find(matches func(args []string) bool) ([]int, error) {
	pids, err := List()
	if err != nil {
		return nil, err
	}
	found := make([]int, 0)
	for _, pid := range pids {
		args, err := Args(pid)
		if err == nil && matches(args) {
			found = append(found, pid)
		}
	}
	sort.Ints(found)
	return found, nil
}
