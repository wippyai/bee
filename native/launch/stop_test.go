// SPDX-License-Identifier: MIT

package launch

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/wippyai/bee/native/hive/rendezvous"
	app "github.com/wippyai/runtime/cmd/app"
)

func stopIntent(t *testing.T) clientIntent {
	t.Helper()
	intent, err := parseClientIntent([]string{"stop"})
	if err != nil || !intent.stop || intent.alone {
		t.Fatalf("stop intent = %+v, %v", intent, err)
	}
	if _, err := parseClientIntent([]string{"stop", "now"}); err == nil {
		t.Fatal("bee stop accepted an argument")
	}
	return intent
}

func TestStopReportsWhenNoOwnerRunsAndStartsNone(t *testing.T) {
	state := t.TempDir()
	owner := &fakeOwner{descriptor: fakeDescriptor(t)}
	seams := owner.seams(filepath.Join(state, rendezvous.DirectoryName))
	var report bytes.Buffer
	seams.report = &report
	if err := runClientEnsuresOwner(context.Background(), clientLaunch(state), seams, joinRequest{Intent: stopIntent(t)}); err != nil {
		t.Fatal(err)
	}
	if report.String() != "Bee is not running for this project\n" || owner.started != 0 || owner.joined != 0 {
		t.Fatalf("report %q, started %d, joined %d", report.String(), owner.started, owner.joined)
	}
}

// bee stop asks the running owner over its authenticated client channel and
// reports once the owner released the state.
func TestStopAsksTheRunningOwnerAndWaitsForItToRelease(t *testing.T) {
	state := t.TempDir()
	owner := &fakeOwner{descriptor: fakeDescriptor(t), started: 1}
	seams := owner.seams(filepath.Join(state, rendezvous.DirectoryName))
	var report bytes.Buffer
	seams.report = &report
	waited := false
	seams.released = func(context.Context, string) error { waited = true; return nil }
	if err := runClientEnsuresOwner(context.Background(), clientLaunch(state), seams, joinRequest{Intent: stopIntent(t)}); err != nil {
		t.Fatal(err)
	}
	if owner.joined != 1 || !owner.lastJoin.Intent.stop || owner.lastJoin.Intent.alone || !waited {
		t.Fatalf("joined %d with %+v, waited %v", owner.joined, owner.lastJoin.Intent, waited)
	}
	if report.String() != "Stopping Bee…\nBee stopped\n" {
		t.Fatalf("report %q", report.String())
	}
}

func TestStopFailsWhenTheOwnerRefusesOrKeepsTheState(t *testing.T) {
	state := t.TempDir()
	owner := &fakeOwner{descriptor: fakeDescriptor(t), started: 1}
	seams := owner.seams(filepath.Join(state, rendezvous.DirectoryName))
	denied := errors.New("DENIED: the host did not grant owner stop")
	seams.join = func(context.Context, joinRequest) error { return denied }
	if err := runClientEnsuresOwner(context.Background(), clientLaunch(state), seams, joinRequest{Intent: stopIntent(t)}); !errors.Is(err, denied) {
		t.Fatalf("refused stop = %v", err)
	}
	seams = owner.seams(filepath.Join(state, rendezvous.DirectoryName))
	held := errors.New("Bee did not stop")
	seams.released = func(context.Context, string) error { return held }
	if err := runClientEnsuresOwner(context.Background(), clientLaunch(state), seams, joinRequest{Intent: stopIntent(t)}); !errors.Is(err, held) {
		t.Fatalf("held state = %v", err)
	}
}

func TestReleasedReturnsOnceNoOwnerHoldsTheState(t *testing.T) {
	if err := waitReleased(context.Background(), t.TempDir()); err != nil {
		t.Fatal(err)
	}
}

// The owner takes the launch identity its starting client handed it and
// clears it, so its own children never inherit it.
func TestOwnerTakesItsLaunchIdentity(t *testing.T) {
	state := t.TempDir()
	host := newHost(systemHostResolver())
	launchID := strings.Repeat("d", 32)
	t.Setenv(ownerLaunchVariable, launchID)
	if _, err := host.Plan(context.Background(), app.Launch{Op: app.OpRun, Command: desktopCommand,
		Args: []string{ownerArgument}, State: state, Dir: state, Explicit: true}); err != nil {
		t.Fatal(err)
	}
	if host.ownerLaunch != launchID {
		t.Fatalf("owner launch = %q", host.ownerLaunch)
	}
	if _, set := os.LookupEnv(ownerLaunchVariable); set {
		t.Fatal("the owner kept its launch identity in its environment")
	}
	t.Setenv(ownerLaunchVariable, "not-an-identity")
	if _, err := newHost(systemHostResolver()).Plan(context.Background(), app.Launch{Op: app.OpRun, Command: desktopCommand,
		Args: []string{ownerArgument}, State: state, Dir: state, Explicit: true}); err == nil {
		t.Fatal("a malformed launch identity was accepted")
	}
}
