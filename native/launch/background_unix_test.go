//go:build meshclient && physicalclient && (linux || darwin)

// SPDX-License-Identifier: MIT
package launch

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"syscall"
	"testing"
	"time"

	application "github.com/wippyai/runtime/api/application"
)

func TestOwnerCommandPreservesLiteralStateAndProject(t *testing.T) {
	root := t.TempDir()
	log, err := os.CreateTemp(root, "owner-log-")
	if err != nil {
		t.Fatal(err)
	}
	defer log.Close()
	request := application.LaunchRequest{Operation: application.RunApplication, Command: "bee", StateDir: filepath.Join(root, "state $literal `literal`"), Directory: root}
	command, err := ownerCommand("/absolute/bee", request, log)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"/absolute/bee", "--state-dir", request.StateDir, "--command", "bee", "run", "start"}
	if !reflect.DeepEqual(command.Args, want) || command.Dir != root || command.Stdin != nil || command.Stdout != log || command.Stderr != log {
		t.Fatalf("wrong command: %#v", command)
	}
	request.Base = true
	if _, err := ownerCommand("/absolute/bee", request, log); err == nil {
		t.Fatal("base accepted")
	}
}

func TestCanceledStartCreatesNoChild(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	command := exec.Command("/does/not/exist")
	if _, err := startDetached(ctx, command); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if command.Process != nil {
		t.Fatal("canceled launch created a process")
	}
}

func TestDetachedOwnerSurvivesLauncherExit(t *testing.T) {
	root := t.TempDir()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	parent := exec.CommandContext(ctx, executable, "-test.run=^TestDetachedOwnerHelper$")
	parent.Env = append(os.Environ(), "BEE_DETACH_ROLE=parent", "BEE_DETACH_ROOT="+root)
	output, err := parent.CombinedOutput()
	if err != nil {
		t.Fatalf("parent: %v\n%s", err, output)
	}
	// Only let the child produce evidence after the launching process has exited.
	if err := os.WriteFile(filepath.Join(root, "release"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	pidBytes, err := os.ReadFile(filepath.Join(root, "pid"))
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(string(pidBytes))
	if err != nil {
		t.Fatal(err)
	}
	finished := false
	t.Cleanup(func() {
		if !finished {
			_ = syscall.Kill(pid, syscall.SIGKILL)
		}
	})
	var proof struct{ Independent, NoTTY bool }
	for {
		data, err := os.ReadFile(filepath.Join(root, "proof"))
		if err == nil && json.Unmarshal(data, &proof) == nil {
			break
		}
		select {
		case <-ctx.Done():
			t.Fatal("detached child did not survive parent", ctx.Err())
		case <-time.After(10 * time.Millisecond):
		}
	}
	if !proof.Independent || !proof.NoTTY {
		t.Fatalf("not detached: %+v", proof)
	}
	if err := os.WriteFile(filepath.Join(root, "stop"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	for {
		if _, err := os.Stat(filepath.Join(root, "exited")); err == nil {
			finished = true
			break
		}
		select {
		case <-ctx.Done():
			t.Fatal("child did not exit")
		case <-time.After(10 * time.Millisecond):
		}
	}
}

func TestDetachedOwnerHelper(t *testing.T) {
	role := os.Getenv("BEE_DETACH_ROLE")
	root := os.Getenv("BEE_DETACH_ROOT")
	if role == "" {
		t.Skip("subprocess helper")
	}
	if role == "parent" {
		executable, err := os.Executable()
		if err != nil {
			t.Fatal(err)
		}
		log, err := os.OpenFile(filepath.Join(root, "owner.log"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if err != nil {
			t.Fatal(err)
		}
		defer log.Close()
		command := exec.Command(executable, "-test.run=^TestDetachedOwnerHelper$")
		command.Env = append(os.Environ(), "BEE_DETACH_ROLE=child")
		command.Stdout, command.Stderr = log, log
		ctx, cancel := context.WithCancel(context.Background())
		child, err := startDetached(ctx, command)
		cancel()
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, "pid"), []byte(strconv.Itoa(child.command.Process.Pid)), 0600); err != nil {
			t.Fatal(err)
		}
		// Wait cancellation observes only; it must not cancel the child.
		if err := child.Wait(ctx); !errors.Is(err, context.Canceled) {
			t.Fatalf("wait=%v", err)
		}
		return
	}
	if role != "child" {
		t.Fatal("unknown helper role")
	}
	deadline := time.Now().Add(10 * time.Second)
	await := func(name string) {
		for {
			if _, err := os.Stat(filepath.Join(root, name)); err == nil {
				return
			}
			if time.Now().After(deadline) {
				t.Fatal("helper timeout", name)
			}
			time.Sleep(10 * time.Millisecond)
		}
	}
	await("release")
	tty, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if tty != nil {
		tty.Close()
	}
	proof := struct{ Independent, NoTTY bool }{Independent: syscall.Getpgrp() == os.Getpid(), NoTTY: err != nil}
	data, err := json.Marshal(proof)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "proof"), data, 0600); err != nil {
		t.Fatal(err)
	}
	await("stop")
	if err := os.WriteFile(filepath.Join(root, "exited"), []byte(fmt.Sprint(os.Getpid())), 0600); err != nil {
		t.Fatal(err)
	}
}
