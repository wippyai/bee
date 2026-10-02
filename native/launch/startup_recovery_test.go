// SPDX-License-Identifier: MIT
package launch

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/wippyai/bee/native/internal/privatefile"
)

func TestInterruptedStartupReleasesOwnerAndStartsFreshProgress(t *testing.T) {
	state := t.TempDir()
	project := t.TempDir()
	_, release, err := prepareOwnerForProject(state, project, true)
	if err != nil {
		t.Fatal(err)
	}
	monitor, err := beginStartup(context.Background(), state, "interrupted", "")
	if err != nil {
		_ = release()
		t.Fatal(err)
	}
	monitor.advance("Upgrading data: threads 27->28")
	if err := monitor.flush(); err != nil {
		t.Fatal(err)
	}
	if err := monitor.stop(); err != nil {
		t.Fatal(err)
	}
	if err := release(); err != nil {
		t.Fatal(err)
	}
	_, releaseAgain, err := prepareOwnerForProject(state, project, true)
	if err != nil {
		t.Fatalf("interrupted startup retained a lock: %v", err)
	}
	defer releaseAgain()
	resumed, err := beginStartup(context.Background(), state, "recovered", "")
	if err != nil {
		t.Fatal(err)
	}
	defer resumed.stop()
	s, err := readStartup(state)
	if err != nil || s.Launch != "recovered" || s.Stopped || s.Ready {
		t.Fatalf("new owner inherited failed progress: %+v %v", s, err)
	}
}

func TestStartupNamesMigrationsAndDoesNotReadUnrelatedLogs(t *testing.T) {
	state := t.TempDir()
	path := filepath.Join(state, "owner-fixture.log")
	if err := os.WriteFile(path, []byte("BEE_STARTUP_PROGRESS Upgrading data: thread 27->28\n"), 0600); err != nil {
		t.Fatal(err)
	}
	monitor, err := beginStartup(context.Background(), state, "fixture", "")
	if err != nil {
		t.Fatal(err)
	}
	defer monitor.stop()
	monitor.cancel()
	<-monitor.done
	monitor.log = path
	if err := monitor.logProgress(); err != nil {
		t.Fatal(err)
	}
	phase, err := monitor.Get(context.Background(), "phase")
	if err != nil || phase != "Upgrading data: thread 27->28" {
		t.Fatalf("phase=%q err=%v", phase, err)
	}
	if _, err := beginStartup(context.Background(), state, "foreign", filepath.Join(t.TempDir(), "owner-other.log")); err == nil {
		t.Fatal("accepted a foreign owner log")
	}
}

func TestStartupDecoderRejectsUnboundedAndUnknownProgress(t *testing.T) {
	for _, data := range []string{
		`{"version":2,"pid":1,"sequence":1,"phase":"booting"}`,
		`{"version":1,"pid":1,"sequence":1,"phase":"booting","permission":true}`,
		`{"version":1,"pid":1,"sequence":0,"phase":"booting"}`,
		`{"version":1,"pid":1,"sequence":1,"phase":"booting"} {}`,
		`{"version":1,"pid":1,"sequence":1,"phase":"` + strings.Repeat("x", 257) + `"}`,
	} {
		state := t.TempDir()
		if err := privatefile.EnsurePrivateDir(filepath.Join(state, startupDirectory)); err != nil {
			t.Fatal(err)
		}
		if err := privatefile.WriteAtomic(filepath.Join(state, startupDirectory, startupFile), []byte(data)); err != nil {
			t.Fatal(err)
		}
		if _, err := readStartup(state); err == nil {
			t.Fatalf("accepted %s", data)
		}
	}
}

func TestBackgroundMigrationPublishesWithoutTerminalContext(t *testing.T) {
	monitor, err := beginStartup(context.Background(), t.TempDir(), "background", "")
	if err != nil {
		t.Fatal(err)
	}
	defer monitor.stop()
	storage := &hostEnvironment{startup: monitor}
	if err := storage.Set(context.Background(), "startup_progress", "Upgrading data: thread 27->28"); err != nil {
		t.Fatalf("background migration has no progress channel: %v", err)
	}
	phase, err := storage.Get(context.Background(), "startup_phase")
	if err != nil || phase != "Upgrading data: thread 27->28" {
		t.Fatalf("background migration was not reported: %q %v", phase, err)
	}
	if err := storage.Set(context.Background(), "startup_progress", "grant authority"); err == nil {
		t.Fatal("progress accepted an unrelated operation")
	}
}

func TestActiveMigrationPhaseSurvivesConcurrentLedgerVerification(t *testing.T) {
	monitor, err := beginStartup(context.Background(), t.TempDir(), "concurrent", "")
	if err != nil {
		t.Fatal(err)
	}
	defer monitor.stop()
	if err := monitor.Set(context.Background(), "progress", "Upgrading data: thread 27->28"); err != nil {
		t.Fatal(err)
	}
	if err := monitor.Set(context.Background(), "progress", "Checking data: approval 5/5"); err != nil {
		t.Fatal(err)
	}
	phase, _ := monitor.Get(context.Background(), "phase")
	if phase != "Upgrading data: thread 27->28" {
		t.Fatalf("a concurrent check hid the active migration: %q", phase)
	}
}

func TestMigrationPublisherIsInactiveAfterStartup(t *testing.T) {
	monitor, err := beginStartup(context.Background(), t.TempDir(), "lifecycle", "")
	if err != nil {
		t.Fatal(err)
	}
	defer monitor.stop()
	storage := &hostEnvironment{startup: monitor}
	phase, err := storage.Get(context.Background(), "startup_progress")
	if err != nil || phase == "" {
		t.Fatalf("startup publication is not active: %q %v", phase, err)
	}
	if err := monitor.Set(context.Background(), "phase", "running"); err != nil {
		t.Fatal(err)
	}
	phase, err = storage.Get(context.Background(), "startup_progress")
	if err != nil || phase != "" {
		t.Fatalf("finished startup still publishes migrations: %q %v", phase, err)
	}
}

func TestRepeatedChecksDoNotHideAStalledMigration(t *testing.T) {
	monitor, err := beginStartup(context.Background(), t.TempDir(), "stalled", "")
	if err != nil {
		t.Fatal(err)
	}
	defer monitor.stop()
	for _, phase := range []string{"Upgrading data: thread 27->28", "Checking data: approval 5/5"} {
		if err := monitor.publish(phase); err != nil {
			t.Fatal(err)
		}
	}
	start := time.Unix(1, 0)
	wait := newStartupWait(start, 10*time.Second)
	monitor.mutex.Lock()
	s := monitor.snapshot
	monitor.mutex.Unlock()
	if err := wait.observe(start, s); err != nil {
		t.Fatal(err)
	}
	for _, phase := range []string{"Checking data: approval", "Checking data: approval 5/5", "Checking data: approval 1/5"} {
		if err := monitor.publish(phase); err != nil {
			t.Fatal(err)
		}
	}
	monitor.mutex.Lock()
	s = monitor.snapshot
	monitor.mutex.Unlock()
	if err := wait.observe(start.Add(10*time.Second), s); err == nil {
		t.Fatal("repeated and regressing checks hid a stalled thread migration")
	}
}

func TestRepeatedCacheVerificationDoesNotRenewStartup(t *testing.T) {
	monitor, err := beginStartup(context.Background(), t.TempDir(), "verification", "")
	if err != nil {
		t.Fatal(err)
	}
	defer monitor.stop()
	path := filepath.Join(monitor.state, "cache", "lua", "verified.lua")
	monitor.cacheProgress(path, true)
	monitor.mutex.Lock()
	first := monitor.snapshot.Sequence
	monitor.mutex.Unlock()
	monitor.cacheProgress(path, true)
	monitor.mutex.Lock()
	duplicate := monitor.snapshot.Sequence
	monitor.mutex.Unlock()
	if duplicate != first {
		t.Fatal("repeated cache reads renewed startup")
	}
	monitor.cacheProgress(path, false)
	monitor.mutex.Lock()
	written := monitor.snapshot.Sequence
	monitor.mutex.Unlock()
	if written <= duplicate {
		t.Fatal("a cache write did not advance startup")
	}
}
