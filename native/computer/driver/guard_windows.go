//go:build windows && amd64

// SPDX-License-Identifier: MIT
package driver

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"golang.org/x/sys/windows"
	"os"
	"os/exec"
	"runtime"
	"syscall"
	"time"
	"unsafe"
)

const guardRole = "--bee-computer-input-guard"
const injectRole = "--bee-computer-input-inject"

var guardLease = 2 * time.Second // Extended only inside the hardware acceptance test executable.

type inputPlan struct {
	Session string  `json:"session"`
	Batch   []input `json:"batch"`
}
type inputReceipt struct {
	Count           int    `json:"count"`
	Cleanup         string `json:"cleanup"`
	PhysicalOverlap bool   `json:"physical_overlap,omitempty"`
}

func rawInput(batch []input) int {
	if len(batch) == 0 {
		return 0
	}
	n, _, _ := sendInput.Call(uintptr(len(batch)), uintptr(unsafe.Pointer(&batch[0])), 40)
	return int(n)
}

// Package-private seam replaced only in the test executable for crash injection.
var injectBatch = rawInput

func readInputLine(r *bufio.Reader, value interface{}) error {
	line, err := r.ReadSlice('\n')
	if err != nil {
		return err
	}
	return json.Unmarshal(line, value)
}

func inputCommand(role string) *exec.Cmd {
	c := exec.Command(os.Args[0], role)
	c.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	return c
}

// InputRole is a private same-executable dispatch seam. It grants no runtime
// authority; host composition must perform admission before spawning a driver.
func InputRole(role string) (bool, error) {
	if role != guardRole && role != injectRole {
		return false, nil
	}
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	r := bufio.NewReaderSize(os.Stdin, 128*1024)
	var plan inputPlan
	if err := readInputLine(r, &plan); err != nil {
		return true, err
	}
	if len(plan.Batch) == 0 || len(plan.Batch) > 512 || len(plan.Session) > 128 {
		return true, errors.New("input plan limit")
	}
	session, err := sessionIdentity()
	if err != nil || session != plan.Session {
		return true, errors.New("input plan session mismatch")
	}
	if err = accessible(); err != nil {
		return true, err
	}
	if role == injectRole {
		return true, json.NewEncoder(os.Stdout).Encode(inputReceipt{Count: injectBatch(plan.Batch)})
	}
	if err = tagTransaction(plan.Batch); err != nil {
		return true, err
	}
	if err = startLifecycle(); err != nil {
		return true, err
	}
	defer stopLifecycle()
	releases, keys := releasePlan(plan.Batch)
	for _, key := range append([]uint16{1, 2, 4, 5, 6, 0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0x5b, 0x5c}, keys...) {
		state, _, _ := user32.NewProc("GetAsyncKeyState").Call(uintptr(key))
		if state&0x8000 != 0 {
			return true, errors.New("pre-existing held input")
		}
	}
	// The entire release plan is retained before readiness and before injection.
	if _, err = fmt.Fprintln(os.Stdout, "armed"); err != nil {
		return true, err
	}
	control := make(chan error, 1)
	go func() {
		var commit string
		err := readInputLine(r, &commit)
		if err == nil && commit != "commit" {
			err = errors.New("invalid input commit")
		}
		control <- err
		if err == nil {
			_, err = r.ReadByte()
			if err == nil {
				err = errors.New("unexpected extra control")
			}
			control <- err
		}
	}()
	deadline := time.NewTimer(guardLease)
	defer deadline.Stop()
	select {
	case err = <-control:
		if err != nil {
			return true, err
		}
	case <-deadline.C:
		return true, errors.New("input commit deadline")
	}
	if err = accessible(); err != nil {
		return true, err
	}
	if foreignInput.Load() {
		return true, errors.New("input overlap before commit")
	}
	child := inputCommand(injectRole)
	job, err := inputJob()
	if err != nil {
		return true, err
	}
	defer windows.CloseHandle(job)
	in, err := child.StdinPipe()
	if err != nil {
		return true, err
	}
	out, err := child.StdoutPipe()
	if err != nil {
		in.Close()
		return true, err
	}
	if err = child.Start(); err != nil {
		in.Close()
		return true, err
	}
	// The worker waits for its plan on stdin. Assign it to the guardian's job
	// before sending any input authority; assignment failure cannot inject.
	if err = assignInput(job, child.Process.Pid); err != nil {
		in.Close()
		child.Process.Kill()
		child.Wait()
		return true, err
	}
	// Only this guardian owns injector termination. Driver/owner death closes
	// control; it does not terminate the guardian before cleanup.
	if err = json.NewEncoder(in).Encode(plan); err != nil {
		child.Process.Kill()
	}
	in.Close()
	type completion struct {
		receipt inputReceipt
		err     error
	}
	finished := make(chan completion, 1)
	go func() {
		var result inputReceipt
		err := readInputLine(bufio.NewReaderSize(out, 4096), &result)
		if waitErr := child.Wait(); err == nil {
			err = waitErr
		}
		finished <- completion{result, err}
	}()
	result := inputReceipt{Count: -1, Cleanup: "unresolved"}
	select {
	case complete := <-finished:
		if complete.err == nil {
			result.Count = complete.receipt.Count
		}
	case <-control:
		child.Process.Kill()
		<-finished
	case <-deadline.C:
		child.Process.Kill()
		<-finished
	case <-foreignInputWake:
		child.Process.Kill()
		<-finished
	}
	// The injector is joined on every path before a release can be attempted.
	if foreignInput.Load() {
		result.Count = -1
		result.Cleanup = "input_overlap"
		result.PhysicalOverlap = foreignPhysical.Load()
	} else if accessible() != nil {
		result.Cleanup = "unresolved"
	} else if result.Count == len(plan.Batch) || result.Count == 0 {
		result.Cleanup = "not_needed"
	} else if accessible() == nil {
		if len(releases) == 0 || rawInput(releases) == len(releases) {
			result.Cleanup = "submitted"
		}
	}
	return true, json.NewEncoder(os.Stdout).Encode(result)
}

func guardedInput(batch []input) bool {
	session, err := sessionIdentity()
	if err != nil {
		return false
	}
	c := inputCommand(guardRole)
	in, err := c.StdinPipe()
	if err != nil {
		return false
	}
	out, err := c.StdoutPipe()
	if err != nil {
		in.Close()
		return false
	}
	if err = c.Start(); err != nil {
		in.Close()
		return false
	}
	// Closing the control pipe asks the guard to recover. Never kill the guard
	// with CommandContext: that would destroy the recovery mechanism itself.
	defer in.Close()
	deadline := time.AfterFunc(3*time.Second, func() { in.Close(); out.Close() })
	defer deadline.Stop()
	r := bufio.NewReaderSize(out, 4096)
	err = json.NewEncoder(in).Encode(inputPlan{Session: session, Batch: batch})
	if err == nil {
		var line string
		line, err = r.ReadString('\n')
		if err == nil && line != "armed\n" {
			err = errors.New("invalid guardian readiness")
		}
	}
	if err == nil {
		err = json.NewEncoder(in).Encode("commit")
	}
	var result inputReceipt
	if err == nil {
		err = readInputLine(r, &result)
	}
	in.Close()
	if err != nil {
		out.Close()
	}
	joined := make(chan error, 1)
	go func() { joined <- c.Wait() }()
	select {
	case waitErr := <-joined:
		if err == nil {
			err = waitErr
		}
	case <-time.After(750 * time.Millisecond):
		// Graceful control-pipe retirement has failed. Killing this guard closes
		// its private job and terminates the injector, but cannot prove key-up.
		// Always retain uncertainty, even if it exits successfully in this race.
		err = errors.New("guardian shutdown exceeded grace; recovery unresolved")
		_ = c.Process.Kill()
		select {
		case <-joined:
		case <-time.After(500 * time.Millisecond):
			// Keep the waiter to reap eventual OS completion; do not hold the
			// caller forever or claim the seat is clean. Owner quarantine fences it.
		}
	}
	if err != nil || result.Count != len(batch) || result.Cleanup != "not_needed" {
		lifecycleRetired.Store(true)
		return false
	}
	return true
}
