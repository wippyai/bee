// SPDX-License-Identifier: MIT
package launch

import (
	"context"
	"testing"
)

func TestStartupObservationWaitsForSupervisionAndReportsExactFailure(t *testing.T) {
	state := t.TempDir()
	monitor, err := beginStartup(context.Background(), state, "slow", "")
	if err != nil {
		t.Fatal(err)
	}
	defer monitor.stop()
	monitor.cancel()
	<-monitor.done
	observe := observeStartup(state, startupSnapshot{}, nil)
	for i := 0; i < 100; i++ {
		if err := observe(); err != nil {
			t.Fatalf("live unchanged owner declared failed: %v", err)
		}
	}
	monitor.mutex.Lock()
	monitor.snapshot.Error = "fixture exact cause\nsecond cause"
	monitor.dirty = true
	monitor.mutex.Unlock()
	if err := monitor.flush(); err != nil {
		t.Fatal(err)
	}
	if err := observe(); err == nil || err.Error() != "fixture exact cause\nsecond cause" {
		t.Fatalf("lost published failure: %v", err)
	}
}

func TestStartupObservationEndsOnOwnerStopAndIgnoresPreviousLaunch(t *testing.T) {
	state := t.TempDir()
	monitor, err := beginStartup(context.Background(), state, "old", "")
	if err != nil {
		t.Fatal(err)
	}
	previous, err := readStartup(state)
	if err != nil {
		t.Fatal(err)
	}
	if err := monitor.stop(); err != nil {
		t.Fatal(err)
	}
	if err := observeStartup(state, previous, nil)(); err != nil {
		t.Fatalf("stale owner failure controlled new launch: %v", err)
	}
	if err := observeStartup(state, startupSnapshot{}, nil)(); err == nil {
		t.Fatal("stopped owner left wait active")
	}
}

func TestStartupProgressBelongsToPublishedOwner(t *testing.T) {
	s := startupSnapshot{Version: 1, PID: 42, Launch: "previous", Sequence: 1, Phase: "Upgrading data"}
	if s.belongsTo(43, "previous") || s.belongsTo(42, "new") || !s.belongsTo(42, "previous") {
		t.Fatal("a stale startup record controls another owner's enrollment")
	}
}
