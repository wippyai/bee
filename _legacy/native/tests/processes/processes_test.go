// SPDX-License-Identifier: MIT

package processes

import (
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"testing"
	"time"
)

const sleeperEnvironment = "BEE_PROCESSES_TEST_SLEEPER"

// TestSleeper is the child body started by startSleeper.
func TestSleeper(t *testing.T) {
	if os.Getenv(sleeperEnvironment) != "1" {
		return
	}
	time.Sleep(30 * time.Second)
	os.Exit(0)
}

// startSleeper re-executes this test binary as a child named by marker and
// reaps it as soon as it exits, as a detached owner is reaped by its parent.
func startSleeper(t *testing.T, marker string) (*exec.Cmd, <-chan struct{}) {
	t.Helper()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	command := exec.Command(executable, "-test.run=^TestSleeper$", marker)
	command.Env = append(os.Environ(), sleeperEnvironment+"=1")
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	reaped := make(chan struct{})
	go func() {
		_ = command.Wait()
		close(reaped)
	}()
	t.Cleanup(func() {
		_ = command.Process.Kill()
		<-reaped
	})
	return command, reaped
}

func TestArgsExecutableAndChildren(t *testing.T) {
	marker := "processes-test-args"
	command, _ := startSleeper(t, marker)
	pid := command.Process.Pid
	deadline := time.Now().Add(5 * time.Second)
	var args []string
	var err error
	for time.Now().Before(deadline) {
		if args, err = Args(pid); err == nil && slices.Contains(args, marker) {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if err != nil || !slices.Equal(args, command.Args) {
		t.Fatalf("Args(%d) = %q, %v", pid, args, err)
	}
	executable, err := Executable(pid)
	if err != nil {
		t.Fatal(err)
	}
	want, err := filepath.EvalSymlinks(command.Path)
	if err != nil {
		t.Fatal(err)
	}
	if got, err := filepath.EvalSymlinks(executable); err != nil || got != want {
		t.Fatalf("Executable(%d) = %q (%v), want %q", pid, executable, err, want)
	}
	children, err := Children(os.Getpid())
	if err != nil || !slices.Contains(children, pid) {
		t.Fatalf("Children(self) = %v, %v; want %d", children, err, pid)
	}
	found, err := Find(func(args []string) bool { return slices.Contains(args, marker) })
	if err != nil || !slices.Equal(found, []int{pid}) {
		t.Fatalf("Find = %v, %v; want [%d]", found, err, pid)
	}
}

func TestHoldRejectsAnotherIdentity(t *testing.T) {
	command, _ := startSleeper(t, "processes-test-identity")
	if handle, err := Hold(command.Process.Pid, func([]string) bool { return false }); err == nil {
		_ = handle.Close()
		t.Fatal("Hold accepted a process its predicate rejected")
	}
}

func TestHandleStopObservesExit(t *testing.T) {
	marker := "processes-test-stop"
	command, reaped := startSleeper(t, marker)
	handle, err := Hold(command.Process.Pid, func(args []string) bool { return slices.Contains(args, marker) })
	if err != nil {
		t.Fatal(err)
	}
	defer handle.Close()
	if handle.Exited(0) {
		t.Fatal("a running process reported exit")
	}
	if handle.Exited(50 * time.Millisecond) {
		t.Fatal("a running process reported exit after a bounded wait")
	}
	if err := handle.Stop(5 * time.Second); err != nil {
		t.Fatal(err)
	}
	if !handle.Exited(0) {
		t.Fatal("Stop returned before the exit was observed")
	}
	select {
	case <-reaped:
		if command.ProcessState.Success() {
			t.Fatal("the stopped process exited normally")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the stopped process was not reaped")
	}
	if err := handle.Signal(9); err != nil {
		t.Fatalf("signal after exit: %v", err)
	}
}

func TestOpenRejectsReapedProcess(t *testing.T) {
	command, reaped := startSleeper(t, "processes-test-reaped")
	pid := command.Process.Pid
	_ = command.Process.Kill()
	<-reaped
	if handle, err := Open(pid); err == nil {
		_ = handle.Close()
		t.Fatalf("Open(%d) held a reaped process", pid)
	}
}
