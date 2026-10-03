// SPDX-License-Identifier: MIT
package launch

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestStartupCacheEventsDoNotSelectPhases(t *testing.T) {
	monitor, err := beginStartup(context.Background(), t.TempDir(), "phases", "")
	if err != nil {
		t.Fatal(err)
	}
	defer monitor.stop()
	monitor.cancel()
	<-monitor.done
	stage := filepath.Join(monitor.state, "cache", "lua", ".seed-stage-fixture")
	if err := os.Mkdir(stage, 0700); err != nil {
		t.Fatal(err)
	}
	monitor.cacheProgress(stage, false)
	phase, err := monitor.Get(context.Background(), "phase")
	if err != nil || phase != "Loading application" {
		t.Fatalf("cache filename selected phase: %q %v", phase, err)
	}
	monitor.advance("Loading registry")
	monitor.cacheProgress(stage, false)
	phase, err = monitor.Get(context.Background(), "phase")
	if err != nil || phase != "Loading registry" {
		t.Fatalf("lost explicitly published phase: %q %v", phase, err)
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
	detail := "Bee owner startup: Settings cannot restore its checkpoint"
	record, err := json.Marshal(map[string]string{"code": "CHECKPOINT_UNSUPPORTED", "component": "bee.apps", "subject": "bee.settings.app:app", "message": detail, "log": log})
	if err != nil {
		t.Fatal(err)
	}
	chain := "Hive supervisor failed before readiness\nstack traceback:\nfull causal chain"
	if err := os.WriteFile(log, append(append([]byte("BEE_STARTUP_FAILED "), record...), []byte("\n"+chain+"\n")...), 0600); err != nil {
		t.Fatal(err)
	}
	cause := errors.New("owner exit status 1: " + chain)
	failure := ownerStartupFailure(cause, state, log, nil)
	want := "Bee could not start: [CHECKPOINT_UNSUPPORTED] bee.apps (bee.settings.app:app): " + detail + "\nFull owner log: " + log + "\nTo boot the shipped bundle, run: bee --state '" + state + "' recover"
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

func TestStartupFailureWithoutRecordPreservesEveryCauseLine(t *testing.T) {
	state := t.TempDir()
	log := filepath.Join(state, "owner-fixture.log")
	if err := os.WriteFile(log, []byte("bee: unrelated diagnostic\n"), 0600); err != nil {
		t.Fatal(err)
	}
	cause := errors.New("Bee owner startup: first cause\nsecond independent cause")
	failure := ownerStartupFailure(cause, state, log, nil)
	if !strings.Contains(failure.Error(), cause.Error()) {
		t.Fatalf("rewrote exact cause: %v", failure)
	}
}

func TestStartupFailureRejectsMalformedRecordsAndKeepsTheirCause(t *testing.T) {
	for _, raw := range []string{`{"code":"x"}`, `{"code":"x","component":"bee.launch","subject":"node","message":"failed","log":"","authority":true}`, `{} {}`} {
		if _, err := decodeStartupFailure(raw); err == nil {
			t.Fatalf("accepted malformed failure: %s", raw)
		}
	}
	state := t.TempDir()
	log := filepath.Join(state, "owner-fixture.log")
	record := startupFailureRecord{Code: "FAILED", Component: "bee.launch", Subject: "node", Message: "exact cause", Log: log}
	encoded, err := json.Marshal(record)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(log, append([]byte(startupFailurePrefix+"{}\n"+startupFailurePrefix), append(encoded, '\n')...), 0600); err != nil {
		t.Fatal(err)
	}
	cause := errors.New("owner exit status 1")
	failure := ownerStartupFailure(cause, state, log, nil)
	if !strings.Contains(failure.Error(), "exact cause") || !strings.Contains(failure.Error(), "decode owner startup failure") || !errors.Is(failure, cause) {
		t.Fatalf("masked record failure: %v", failure)
	}
}

func TestOwnerPublishesStructuredFailureToStartupObserver(t *testing.T) {
	state := t.TempDir()
	log := filepath.Join(state, "owner-fixture.log")
	record := startupFailureRecord{Code: "FAILED", Component: "bee.launch", Subject: "workspace", Message: "exact cause\nsecond cause", Log: log}
	encoded, err := json.Marshal(record)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(log, append([]byte(startupFailurePrefix), append(encoded, '\n')...), 0600); err != nil {
		t.Fatal(err)
	}
	monitor, err := beginStartup(context.Background(), state, "failure", log)
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
	if err := observeStartup(state, startupSnapshot{}, nil)(); err == nil || err.Error() != record.detail() {
		t.Fatalf("rewrote published failure: %v", err)
	}
}

func TestStartupLogPreservesAValidRecordAcrossReadChunks(t *testing.T) {
	state := t.TempDir()
	log := filepath.Join(state, "owner-fixture.log")
	record := startupFailureRecord{Code: "FAILED", Component: "bee.launch", Subject: "workspace", Message: strings.Repeat("root cause ", 1000), Log: log}
	encoded, err := json.Marshal(record)
	if err != nil {
		t.Fatal(err)
	}
	padding := strings.Repeat("diagnostic\n", 5500)
	if err := os.WriteFile(log, append([]byte(padding+startupFailurePrefix), append(encoded, '\n')...), 0600); err != nil {
		t.Fatal(err)
	}
	monitor, err := beginStartup(context.Background(), state, "long-failure", log)
	if err != nil {
		t.Fatal(err)
	}
	defer monitor.stop()
	monitor.cancel()
	<-monitor.done
	for i := 0; i < 2; i++ {
		if err := monitor.logProgress(); err != nil {
			t.Fatal(err)
		}
	}
	if err := monitor.flush(); err != nil {
		t.Fatal(err)
	}
	if err := observeStartup(state, startupSnapshot{}, nil)(); err == nil || err.Error() != record.detail() {
		t.Fatalf("truncated a structured owner cause across chunks: %v", err)
	}
}
