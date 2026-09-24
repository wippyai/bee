// SPDX-License-Identifier: MIT

//go:build darwin

package processes

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"path/filepath"
	"time"

	"golang.org/x/sys/unix"
)

// List returns every PID in the kernel process table.
func List() ([]int, error) {
	table, err := unix.SysctlKinfoProcSlice("kern.proc.all")
	if err != nil {
		return nil, err
	}
	pids := make([]int, 0, len(table))
	for _, process := range table {
		pids = append(pids, int(process.Proc.P_pid))
	}
	return pids, nil
}

// Children returns the direct children of parent.
func Children(parent int) ([]int, error) {
	table, err := unix.SysctlKinfoProcSlice("kern.proc.all")
	if err != nil {
		return nil, err
	}
	children := make([]int, 0)
	for _, process := range table {
		if int(process.Eproc.Ppid) == parent {
			children = append(children, int(process.Proc.P_pid))
		}
	}
	return children, nil
}

// procargs reads KERN_PROCARGS2: argc, the executable path, alignment NULs and
// then argc NUL-terminated arguments.
func procargs(pid int) (string, []string, error) {
	data, err := unix.SysctlRaw("kern.procargs2", pid)
	if err != nil {
		return "", nil, fmt.Errorf("read arguments of process %d: %w", pid, err)
	}
	if len(data) < 4 {
		return "", nil, fmt.Errorf("process %d arguments are truncated", pid)
	}
	argc := int(binary.LittleEndian.Uint32(data[:4]))
	rest := data[4:]
	end := bytes.IndexByte(rest, 0)
	if end < 0 {
		return "", nil, fmt.Errorf("process %d executable path is unterminated", pid)
	}
	executable := string(rest[:end])
	rest = bytes.TrimLeft(rest[end:], "\x00")
	args := make([]string, 0, argc)
	for len(args) < argc {
		end = bytes.IndexByte(rest, 0)
		if end < 0 {
			return "", nil, fmt.Errorf("process %d argument %d is unterminated", pid, len(args))
		}
		args = append(args, string(rest[:end]))
		rest = rest[end+1:]
	}
	if len(args) == 0 {
		return "", nil, fmt.Errorf("process %d has no arguments", pid)
	}
	return executable, args, nil
}

// Args returns the exact argument vector of pid.
func Args(pid int) ([]string, error) {
	_, args, err := procargs(pid)
	return args, err
}

// Executable returns the resolved path of the program image pid is running,
// as Linux reports it through /proc/PID/exe.
func Executable(pid int) (string, error) {
	executable, _, err := procargs(pid)
	if err != nil {
		return "", err
	}
	return filepath.EvalSymlinks(executable)
}

// Handle holds one process through a kqueue NOTE_EXIT registration.
type Handle struct {
	pid    int
	kq     int
	exited bool
}

// Open registers for the exit of pid.
func Open(pid int) (*Handle, error) {
	kq, err := unix.Kqueue()
	if err != nil {
		return nil, err
	}
	change := unix.Kevent_t{Fflags: unix.NOTE_EXIT}
	unix.SetKevent(&change, pid, unix.EVFILT_PROC, unix.EV_ADD|unix.EV_ONESHOT)
	if _, err := unix.Kevent(kq, []unix.Kevent_t{change}, nil, nil); err != nil {
		_ = unix.Close(kq)
		return nil, fmt.Errorf("hold process %d: %w", pid, err)
	}
	return &Handle{pid: pid, kq: kq}, nil
}

// PID returns the held process ID.
func (h *Handle) PID() int { return h.pid }

// Exited reports whether the held process exits within timeout. The exit
// event is delivered once, so the handle latches it.
func (h *Handle) Exited(timeout time.Duration) bool {
	if h.exited || h.kq < 0 {
		return true
	}
	deadline := time.Now().Add(timeout)
	events := make([]unix.Kevent_t, 1)
	for {
		remaining := unix.NsecToTimespec(max(time.Until(deadline), 0).Nanoseconds())
		n, err := unix.Kevent(h.kq, nil, events, &remaining)
		if errors.Is(err, unix.EINTR) {
			continue
		}
		if err == nil && n > 0 {
			h.exited = true
		}
		return h.exited
	}
}

// Signal delivers sig to the held process while its exit is unobserved.
// macOS has no descriptor-bound signal: a process that exits and is reaped
// between the exit check and kill(2) leaves its PID open to reuse.
func (h *Handle) Signal(sig unix.Signal) error {
	if h.kq < 0 {
		return errors.New("process handle is closed")
	}
	if h.Exited(0) {
		return nil
	}
	if err := unix.Kill(h.pid, sig); err != nil && !errors.Is(err, unix.ESRCH) {
		return err
	}
	return nil
}

// Close releases the kqueue.
func (h *Handle) Close() error {
	if h.kq < 0 {
		return nil
	}
	kq := h.kq
	h.kq = -1
	return unix.Close(kq)
}
