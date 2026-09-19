//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package launch

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/wippyai/bee/native/hive/rendezvous"
	"github.com/wippyai/runtime/api/boot"
	app "github.com/wippyai/runtime/cmd/app"
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

// ownedHost blocks inside the model's host preparation, which runs only after
// the runner holds the real application state lock. It therefore holds the state
// exactly as a live owner does, without a bundle or a second lock primitive.
type ownedHost struct{ started chan struct{} }

func (h ownedHost) Plan(context.Context, app.Launch) (app.Plan, error) {
	return app.Plan{Prepare: func(ctx context.Context) (boot.Config, func() error, error) {
		close(h.started)
		<-ctx.Done()
		return nil, nil, ctx.Err()
	}}, nil
}

// TestWarmLaunchUsesRuntimeLockAndFreeProbeReleasesIt proves the client's
// ownership question is answered by the runtime's own application lock: a free
// state reports no owner, a state an owner holds reports one, and the probe
// itself leaves an absent state absent.
func TestWarmLaunchUsesRuntimeLockAndFreeProbeReleasesIt(t *testing.T) {
	state := filepath.Join(t.TempDir(), "state")
	busy, err := app.Owned(state)
	if err != nil || busy {
		t.Fatal(busy, err)
	}
	if _, err := os.Lstat(state); !os.IsNotExist(err) {
		t.Fatalf("free probe created state: %v", err)
	}
	started := make(chan struct{})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	executable := app.Executable{Name: "owner-probe", Command: "holder", Host: ownedHost{started: started}}
	go func() { done <- app.Run(ctx, executable, []string{"--state", state, "run"}) }()
	select {
	case <-started:
	case <-time.After(10 * time.Second):
		t.Fatal("owner did not reach lock-held preparation")
	}
	busy, err = app.Owned(state)
	if err != nil || !busy {
		t.Fatal("live application lock was not recognized", busy, err)
	}
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatal("owner did not stop on cancellation", err)
	}
	busy, err = app.Owned(state)
	if err != nil || busy {
		t.Fatal("released application lock still reported owned", busy, err)
	}
}

func TestOwnerProbeDoesNotTreatFilesystemFailureAsContention(t *testing.T) {
	// A state path whose parent is a regular file cannot open a lock file, so
	// the probe must report the failure rather than a false owner. An absent
	// state is deliberately not a failure; that is the model's contract.
	blocked := filepath.Join(t.TempDir(), "state")
	if err := os.WriteFile(blocked, []byte("not a directory"), 0o600); err != nil {
		t.Fatal(err)
	}
	if busy, err := app.Owned(blocked); err == nil || busy {
		t.Fatal("filesystem failure was accepted as an owner", busy, err)
	}
}
