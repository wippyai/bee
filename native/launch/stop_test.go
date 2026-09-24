// SPDX-License-Identifier: MIT

package launch

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	app "github.com/wippyai/runtime/cmd/app"
)

type fakeStop struct {
	held      bool
	releaseOn int
	probes    int
	signalled []int
}

func (f *fakeStop) seams() stopSeams {
	return stopSeams{
		owned: func(string) (bool, error) {
			f.probes++
			if f.held && f.releaseOn > 0 && len(f.signalled) > 0 && f.probes >= f.releaseOn {
				f.held = false
			}
			return f.held, nil
		},
		signal:   func(pid int) error { f.signalled = append(f.signalled, pid); return nil },
		interval: time.Millisecond,
		timeout:  200 * time.Millisecond,
	}
}

func writePID(t *testing.T, state string, pid int) {
	t.Helper()
	if err := os.MkdirAll(ownerDirectory(state), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(ownerDirectory(state), ownerPIDName), []byte(strconv.Itoa(pid)+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestStopReportsWhenNoOwnerRuns(t *testing.T) {
	state := t.TempDir()
	stop := &fakeStop{}
	var report bytes.Buffer
	if err := stopOwner(context.Background(), state, &report, stop.seams()); err != nil {
		t.Fatal(err)
	}
	if report.String() != "Bee is not running for this project\n" || len(stop.signalled) != 0 {
		t.Fatalf("report %q, signals %v", report.String(), stop.signalled)
	}
}

func TestStopSignalsTheOwnerAndWaitsForItToRelease(t *testing.T) {
	state := t.TempDir()
	writePID(t, state, 4242)
	stop := &fakeStop{held: true, releaseOn: 3}
	var report bytes.Buffer
	if err := stopOwner(context.Background(), state, &report, stop.seams()); err != nil {
		t.Fatal(err)
	}
	if len(stop.signalled) != 1 || stop.signalled[0] != 4242 {
		t.Fatalf("signals %v", stop.signalled)
	}
	if report.String() != "Stopping Bee…\nBee stopped\n" {
		t.Fatalf("report %q", report.String())
	}
}

func TestStopFailsWhenTheOwnerDoesNotStop(t *testing.T) {
	state := t.TempDir()
	writePID(t, state, 4242)
	stop := &fakeStop{held: true}
	if err := stopOwner(context.Background(), state, &bytes.Buffer{}, stop.seams()); err == nil {
		t.Fatal("an owner that keeps the state was reported stopped")
	}
}

func TestStopRefusesAnOwnerWithoutARecordedProcess(t *testing.T) {
	state := t.TempDir()
	stop := &fakeStop{held: true}
	err := stopOwner(context.Background(), state, &bytes.Buffer{}, stop.seams())
	if err == nil || len(stop.signalled) != 0 {
		t.Fatalf("err %v, signals %v", err, stop.signalled)
	}
}

func TestOwnerRecordsItsProcessWhileItHoldsTheState(t *testing.T) {
	state := t.TempDir()
	if err := os.MkdirAll(ownerDirectory(state), 0o700); err != nil {
		t.Fatal(err)
	}
	release, err := recordOwnerProcess(state)
	if err != nil {
		t.Fatal(err)
	}
	pid, err := readOwnerProcess(state)
	if err != nil || pid != os.Getpid() {
		t.Fatalf("pid %d, err %v", pid, err)
	}
	if err := release(); err != nil {
		t.Fatal(err)
	}
	if _, err := readOwnerProcess(state); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("released owner still records a process: %v", err)
	}
}

func TestPlanRoutesStopWithoutAClientOrOwner(t *testing.T) {
	state := t.TempDir()
	host := newHost(systemHostResolver())
	project := makeProject(t)
	plan, err := host.Plan(context.Background(), app.Launch{
		Op: app.OpRun, Command: desktopCommand, Args: []string{"stop"},
		State: state, Dir: project, Explicit: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if plan.Run == nil || plan.Prepare != nil || plan.Command != "" || host.ownerState != "" {
		t.Fatalf("stop plan = %#v", plan)
	}
	if _, err := host.Plan(context.Background(), app.Launch{
		Op: app.OpRun, Command: desktopCommand, Args: []string{"stop", "now"},
		State: state, Dir: project, Explicit: true,
	}); err == nil {
		t.Fatal("bee stop accepted an argument")
	}
}
