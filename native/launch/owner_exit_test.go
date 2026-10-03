//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"errors"
	"github.com/wippyai/bee/native/hive/rendezvous"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestOwnerExitObserverChild(t *testing.T) {
	if os.Getenv("BEE_OWNER_EXIT_OBSERVER_CHILD") != "1" {
		return
	}
	for {
		time.Sleep(time.Hour)
	}
}

func TestOwnerExitObserverWaitsForThePinnedProcess(t *testing.T) {
	command := exec.Command(os.Args[0], "-test.run=^TestOwnerExitObserverChild$")
	command.Env = append(os.Environ(), "BEE_OWNER_EXIT_OBSERVER_CHILD=1")
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = command.Process.Kill()
		_ = command.Wait()
	}()

	observer, err := holdOwnerProcessExit(command.Process.Pid)
	if err != nil {
		t.Fatal(err)
	}
	defer observer.close()
	if err := command.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := observer.wait(ctx); err != nil {
		t.Fatal(err)
	}
	if err := command.Wait(); err == nil {
		t.Fatal("owner observer child exited successfully after being killed")
	}
}

func TestStaleOwnerCleanupVerifiesTheProcessIsGoneAndPreservesOtherProcesses(t *testing.T) {
	command := exec.Command(os.Args[0], "-test.run=^NoSuchTest$")
	if err := command.Run(); err != nil {
		t.Fatal(err)
	}
	state := t.TempDir()
	if err := os.Chmod(state, 0o700); err != nil {
		t.Fatal(err)
	}
	directory := filepath.Join(state, rendezvous.DirectoryName)
	store, err := rendezvous.New(directory)
	if err != nil {
		t.Fatal(err)
	}
	record := fakeDescriptor(t)
	record.OwnerPID = command.Process.Pid
	if err := store.Publish(context.Background(), record); err != nil {
		t.Fatal(err)
	}
	cleared, err := clearStaleOwner(context.Background(), state, holdOwnerProcessExit)
	if err != nil || !cleared {
		t.Fatalf("dead recorded owner: cleared %v, error %v", cleared, err)
	}
	if _, err := store.Read(context.Background()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stale descriptor remained: %v", err)
	}
	// A live unrelated process using the recorded PID must never be signaled or
	// mistaken for a dead owner, even when no process holds the Bee state lock.
	record.OwnerPID = os.Getpid()
	if err := store.Publish(context.Background(), record); err != nil {
		t.Fatal(err)
	}
	cleared, err = clearStaleOwner(context.Background(), state, holdOwnerProcessExit)
	if err == nil || cleared {
		t.Fatalf("live reused PID: cleared %v, error %v", cleared, err)
	}
	if _, err := store.Read(context.Background()); err != nil {
		t.Fatalf("live PID descriptor lost: %v", err)
	}
}
