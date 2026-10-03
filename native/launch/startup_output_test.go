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
)

func TestStartupLoadsApplicationBeforeCacheInstallation(t *testing.T) {
	monitor, err := beginStartup(context.Background(), t.TempDir(), "phases", "")
	if err != nil {
		t.Fatal(err)
	}
	defer monitor.stop()
	monitor.cancel()
	<-monitor.done
	phase, err := monitor.Get(context.Background(), "phase")
	if err != nil || phase != "Loading application" {
		t.Fatalf("initial phase = %q, %v", phase, err)
	}
	stage := filepath.Join(monitor.state, "cache", "lua", ".seed-stage-fixture")
	if err := os.Mkdir(stage, 0700); err != nil {
		t.Fatal(err)
	}
	if err := monitor.cacheInstallation(stage); err != nil {
		t.Fatal(err)
	}
	phase, _ = monitor.Get(context.Background(), "phase")
	if phase != "Installing Lua cache" {
		t.Fatalf("extraction phase = %q", phase)
	}
	if err := os.Remove(stage); err != nil {
		t.Fatal(err)
	}
	if err := monitor.cacheInstallation(stage); err != nil {
		t.Fatal(err)
	}
	phase, _ = monitor.Get(context.Background(), "phase")
	if phase != "Loading registry" {
		t.Fatalf("completed extraction phase = %q", phase)
	}
	monitor.advance("Starting services")
	if err := monitor.cacheInstallation(stage); err != nil {
		t.Fatal(err)
	}
	phase, _ = monitor.Get(context.Background(), "phase")
	if phase != "Starting services" {
		t.Fatalf("late cache event regressed phase = %q", phase)
	}
}

func TestStartupObserverUpdatesOneLineWithTheCurrentPhase(t *testing.T) {
	state := t.TempDir()
	monitor, err := beginStartup(context.Background(), state, "output", "")
	if err != nil {
		t.Fatal(err)
	}
	defer monitor.stop()
	var output bytes.Buffer
	line := &startupLine{report: &output}
	observe := observeStartup(state, startupSnapshot{}, line)
	monitor.advance("Starting services")
	if err := monitor.flush(); err != nil {
		t.Fatal(err)
	}
	for _, phase := range []string{"Starting services", "Loading application", "Starting services", "Starting services"} {
		monitor.advance(phase)
		if err := monitor.flush(); err != nil {
			t.Fatal(err)
		}
		if err := observe(); err != nil {
			t.Fatal(err)
		}
	}
	if got := output.String(); got != "\r\x1b[2KStarting services…\r\x1b[2KLoading application…\r\x1b[2KStarting services…" {
		t.Fatalf("phase output = %q", got)
	}
}

func TestStartupProgressClearsBeforeDesktopOrFailureOutput(t *testing.T) {
	var output bytes.Buffer
	line := &startupLine{report: &output}
	if err := line.show("Loading application"); err != nil {
		t.Fatal(err)
	}
	if err := line.show("Starting services"); err != nil {
		t.Fatal(err)
	}
	if err := line.clear(); err != nil {
		t.Fatal(err)
	}
	if err := line.clear(); err != nil {
		t.Fatal(err)
	}
	if got := output.String(); got != "\r\x1b[2KLoading application…\r\x1b[2KStarting services…\r\x1b[2K" {
		t.Fatalf("progress output = %q", got)
	}
}

func TestStartupFailureNamesCauseLogAndRecovery(t *testing.T) {
	state := t.TempDir()
	log := filepath.Join(state, "owner-fixture.log")
	detail := "app Settings could not be restored: checkpoint schema is unsupported"
	chain := "Hive supervisor failed before retained workspace readiness: " + detail + "\nstack traceback:\nfull causal chain"
	if err := os.WriteFile(log, []byte("BEE_STARTUP_FAILED "+chain+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	cause := errors.New("the running Bee owner did not enroll this client: " + chain + "; try bee stop")
	failure := ownerStartupFailure(cause, state, log, nil)
	want := "Bee could not start: " + detail + "\nFull owner log: " + log + "\nTo boot the shipped bundle, run: bee --state '" + state + "' recover"
	if got := failure.Error(); got != want {
		t.Fatalf("failure output = %q, want %q", got, want)
	}
	if !errors.Is(failure, cause) {
		t.Fatal("lost the original causal chain")
	}
	data, err := os.ReadFile(log)
	if err != nil || !strings.Contains(string(data), "full causal chain") {
		t.Fatalf("lost owner log: %v", err)
	}
}

func TestStartupFailureReportsOwnerCleanupAndLogReadFailures(t *testing.T) {
	state := t.TempDir()
	path := filepath.Join(state, "owner-missing.log")
	cause := errors.New("startup failed")
	abort := errors.New("observe owner exit: permission denied")
	failure := ownerStartupFailure(errors.Join(cause, abort), state, path, abort)
	if !strings.Contains(failure.Error(), "stop failed owner: observe owner exit: permission denied") || !strings.Contains(failure.Error(), "read owner log:") {
		t.Fatalf("failure masked an error: %v", failure)
	}
	if !errors.Is(failure, cause) || !errors.Is(failure, abort) || !errors.Is(failure, os.ErrNotExist) {
		t.Fatal("lost failure causes")
	}
}

func TestStartupObserverKeepsOwnerLogOutOfProgress(t *testing.T) {
	state := t.TempDir()
	log := filepath.Join(state, "owner-fixture.log")
	ownerOutput := "owner diagnostic before boot\nBEE_STARTUP_PROGRESS Checking data: workspace 1/1\n"
	if err := os.WriteFile(log, []byte(ownerOutput), 0600); err != nil {
		t.Fatal(err)
	}
	monitor, err := beginStartup(context.Background(), state, "quiet-startup", log)
	if err != nil {
		t.Fatal(err)
	}
	defer monitor.stop()
	monitor.cancel()
	<-monitor.done
	if err := monitor.logProgress(); err != nil {
		t.Fatal(err)
	}
	if err := monitor.flush(); err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	observe := observeStartup(state, startupSnapshot{}, &startupLine{report: &output})
	if err := observe(); err != nil {
		t.Fatal(err)
	}
	if got := output.String(); got != "\r\x1b[2KChecking data: workspace 1/1…" {
		t.Fatalf("forwarded owner lines during boot: %q", got)
	}
	data, err := os.ReadFile(log)
	if err != nil || string(data) != ownerOutput {
		t.Fatalf("owner log changed: %q, %v", data, err)
	}
}
