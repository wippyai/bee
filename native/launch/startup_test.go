// SPDX-License-Identifier: MIT
package launch

import (
	"testing"
	"time"
)

func TestStartupWaitTracksDelayedPhaseAndNamesARealStall(t *testing.T) {
	start := time.Unix(1, 0)
	wait := newStartupWait(start, 10*time.Second)
	for sequence := uint64(1); sequence <= 8; sequence++ {
		now := start.Add(time.Duration(sequence) * 9 * time.Second)
		value := startupSnapshot{Version: 1, PID: 42, Launch: "attempt", Sequence: sequence, Phase: "Upgrading data: threads 27->28"}
		if err := wait.observe(now, value); err != nil {
			t.Fatalf("progressing upgrade killed at %s: %v", now.Sub(start), err)
		}
	}
	stalled := startupSnapshot{Version: 1, PID: 42, Launch: "attempt", Sequence: 8, Phase: "Upgrading data: threads 27->28"}
	if err := wait.observe(start.Add(82*time.Second), stalled); err == nil {
		t.Fatal("a repeated heartbeat hid a real stall")
	}
}

func TestStartupProgressRefusesDuplicateAndRegressingCounters(t *testing.T) {
	start := time.Unix(1, 0)
	wait := newStartupWait(start, 10*time.Second)
	value := startupSnapshot{Version: 1, PID: 42, Launch: "attempt", Sequence: 3, Phase: "Applying workspace migration"}
	if err := wait.observe(start, value); err != nil {
		t.Fatal(err)
	}
	value.Sequence = 2
	if err := wait.observe(start.Add(9*time.Second), value); err != nil {
		t.Fatal(err)
	}
	if err := wait.observe(start.Add(10*time.Second), value); err == nil {
		t.Fatal("regressing progress postponed the stall")
	}
}

func TestStartupProgressBelongsToPublishedOwner(t *testing.T) {
	s := startupSnapshot{Version: 1, PID: 42, Launch: "previous", Sequence: 1, Phase: "Upgrading data"}
	if s.belongsTo(43, "previous") || s.belongsTo(42, "new") || !s.belongsTo(42, "previous") {
		t.Fatal("a stale startup record controls another owner's enrollment")
	}
}
