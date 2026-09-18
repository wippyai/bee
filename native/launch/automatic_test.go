//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package launch

import (
	"context"
	"errors"
	"os"
	"testing"

	"github.com/wippyai/bee/native/hive/rendezvous"
	"github.com/wippyai/runtime/application/statelock"
)

func TestFailedOwnerNeverFallsBackToStaleDiscovery(t *testing.T) {
	done := make(chan struct{})
	close(done)
	failure := errors.New("owner boot failed")
	reads := 0
	err := waitOwnerPublication(context.Background(), func(context.Context) (rendezvous.Descriptor, error) {
		reads++
		return rendezvous.Descriptor{Execution: "stale"}, nil
	}, rendezvous.Descriptor{}, done, func(context.Context) error { return failure })
	if err != failure || reads != 0 {
		t.Fatal("failed child accepted stale discovery", err, reads)
	}
}

func TestUnchangedOwnerHintDoesNotProveStartup(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	previous := rendezvous.Descriptor{Execution: "old"}
	err := waitOwnerPublication(ctx, func(context.Context) (rendezvous.Descriptor, error) { cancel(); return previous, nil }, previous, make(chan struct{}), func(context.Context) error { t.Fatal("wait called on live child"); return nil })
	if !errors.Is(err, context.Canceled) {
		t.Fatal("stale hint accepted", err)
	}
}

func TestReplacementHintAllowsFreshAdmissionAttempt(t *testing.T) {
	err := waitOwnerPublication(context.Background(), func(context.Context) (rendezvous.Descriptor, error) {
		return rendezvous.Descriptor{Execution: "new"}, nil
	}, rendezvous.Descriptor{Execution: "old"}, make(chan struct{}), func(context.Context) error { t.Fatal("wait called on live child"); return nil })
	if err != nil {
		t.Fatal(err)
	}
}

func TestMissingPublicationRemainsCancelable(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	err := waitOwnerPublication(ctx, func(context.Context) (rendezvous.Descriptor, error) {
		cancel()
		return rendezvous.Descriptor{}, os.ErrNotExist
	}, rendezvous.Descriptor{}, make(chan struct{}), func(context.Context) error { return nil })
	if !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
}

func TestWarmLaunchUsesRuntimeLockAndFreeProbeReleasesIt(t *testing.T) {
	state := t.TempDir()
	busy, err := ownerLockBusy(state)
	if err != nil || busy {
		t.Fatal(busy, err)
	}
	unlock, err := statelock.Acquire(state)
	if err != nil {
		t.Fatal("free probe retained lock", err)
	}
	defer unlock()
	busy, err = ownerLockBusy(state)
	if err != nil || !busy {
		t.Fatal("live runtime lock was not recognized", busy, err)
	}
}

func TestOwnerProbeDoesNotTreatFilesystemFailureAsContention(t *testing.T) {
	if busy, err := ownerLockBusy(t.TempDir() + "/missing"); err == nil || busy {
		t.Fatal("filesystem failure was accepted as an owner", busy, err)
	}
}
