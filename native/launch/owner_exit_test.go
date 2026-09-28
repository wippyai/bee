//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"os"
	"os/exec"
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
