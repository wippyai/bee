// SPDX-License-Identifier: MIT

//go:build linux

package processes

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

// List returns every PID visible in /proc.
func List() ([]int, error) {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil, err
	}
	pids := make([]int, 0, len(entries))
	for _, entry := range entries {
		if pid, err := strconv.Atoi(entry.Name()); err == nil {
			pids = append(pids, pid)
		}
	}
	return pids, nil
}

// Children returns the direct children of parent across all of its threads.
func Children(parent int) ([]int, error) {
	tasks, err := filepath.Glob(fmt.Sprintf("/proc/%d/task/*/children", parent))
	if err != nil {
		return nil, err
	}
	if len(tasks) == 0 {
		return nil, fmt.Errorf("process %d has no readable tasks", parent)
	}
	children := make([]int, 0)
	for _, task := range tasks {
		data, err := os.ReadFile(task)
		if err != nil {
			continue
		}
		for _, field := range strings.Fields(string(data)) {
			if pid, err := strconv.Atoi(field); err == nil {
				children = append(children, pid)
			}
		}
	}
	return children, nil
}

// Args returns the exact argument vector of pid.
func Args(pid int) ([]string, error) {
	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid))
	if err != nil {
		return nil, err
	}
	if len(data) == 0 {
		return nil, fmt.Errorf("process %d has no arguments", pid)
	}
	parts := bytes.Split(bytes.TrimSuffix(data, []byte{0}), []byte{0})
	args := make([]string, len(parts))
	for i, part := range parts {
		args[i] = string(part)
	}
	return args, nil
}

// Executable returns the path of the program image pid is running.
func Executable(pid int) (string, error) {
	return os.Readlink(fmt.Sprintf("/proc/%d/exe", pid))
}

// Handle holds one process through a pidfd.
type Handle struct {
	pid int
	fd  int
}

// Open holds pid through a pidfd.
func Open(pid int) (*Handle, error) {
	fd, err := unix.PidfdOpen(pid, 0)
	if err != nil {
		return nil, fmt.Errorf("hold process %d: %w", pid, err)
	}
	return &Handle{pid: pid, fd: fd}, nil
}

// PID returns the held process ID.
func (h *Handle) PID() int { return h.pid }

// Exited reports whether the held process exits within timeout.
func (h *Handle) Exited(timeout time.Duration) bool {
	if h.fd < 0 {
		return true
	}
	poll := []unix.PollFd{{Fd: int32(h.fd), Events: unix.POLLIN}}
	deadline := time.Now().Add(timeout)
	for {
		_, err := unix.Poll(poll, int(max(time.Until(deadline), 0).Milliseconds()))
		if !errors.Is(err, unix.EINTR) {
			return err == nil && poll[0].Revents != 0
		}
	}
}

// Signal delivers sig to the held process; an exited process needs none.
func (h *Handle) Signal(sig unix.Signal) error {
	if h.fd < 0 {
		return errors.New("process handle is closed")
	}
	if err := unix.PidfdSendSignal(h.fd, sig, nil, 0); err != nil && !errors.Is(err, unix.ESRCH) {
		return err
	}
	return nil
}

// Close releases the pidfd.
func (h *Handle) Close() error {
	if h.fd < 0 {
		return nil
	}
	fd := h.fd
	h.fd = -1
	return unix.Close(fd)
}
