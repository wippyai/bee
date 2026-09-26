// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// cutoverFake records the handoff sequence a cutover drives.
type cutoverFake struct {
	order          []string
	stopErr        error
	compatibleErr  error
	compatibleWith string
	releaseErr     error
	startErr       func(executable string) error
	current        string
}

func (f *cutoverFake) seams() cutoverSeams {
	return cutoverSeams{
		stopOld: func(context.Context, string, string) error {
			f.order = append(f.order, "stop")
			return f.stopErr
		},
		stopOldCompatible: func(_ context.Context, _ string, previous string) error {
			f.order = append(f.order, "compatible-stop")
			f.compatibleWith = previous
			return f.compatibleErr
		},
		waitReleased: func(context.Context, string) error {
			f.order = append(f.order, "release")
			return f.releaseErr
		},
		start: func(_ context.Context, _, _, executable string) error {
			f.order = append(f.order, "start:"+filepath.Base(executable))
			if f.startErr != nil {
				return f.startErr(executable)
			}
			return nil
		},
		currentExecutable: func() (string, error) { return f.current, nil },
	}
}

// cutoverScript writes an executable shell script standing in for a native
// binary: it answers `help` exactly like the readiness self-test needs.
func cutoverScript(t *testing.T, dir, name, body string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body+"\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	return path
}

func goodCandidate(t *testing.T, dir, name string) string {
	t.Helper()
	return cutoverScript(t, dir, name, `if [ "$1" = help ]; then echo "bee [--state DIR] [COMMAND]"; exit 0; fi; exit 0`)
}

func cutoverRequest(state, dir, candidate string) CutoverRequest {
	digest, err := sha256File(candidate)
	if err != nil {
		panic(err)
	}
	return CutoverRequest{State: state, Dir: dir, Candidate: candidate, ConfirmedDigest: digest}
}

func TestCutoverVerifiesDigestAndHandsTheLock(t *testing.T) {
	state := t.TempDir()
	bin := t.TempDir()
	candidate := goodCandidate(t, bin, "bee-new")
	current := goodCandidate(t, bin, "bee-old")
	fake := &cutoverFake{current: current}
	result, err := runCutover(context.Background(), cutoverRequest(state, state, candidate), fake.seams())
	if err != nil {
		t.Fatal(err)
	}
	wantOrder := []string{"stop", "release", "start:bee-new"}
	if strings.Join(fake.order, ",") != strings.Join(wantOrder, ",") {
		t.Fatalf("handoff order = %v, want %v", fake.order, wantOrder)
	}
	currentDigest, err := sha256File(current)
	if err != nil {
		t.Fatal(err)
	}
	retainedDigest, err := sha256File(result.Previous)
	if err != nil {
		t.Fatal(err)
	}
	if retainedDigest != currentDigest {
		t.Fatal("the running binary was not retained for rollback")
	}
	if result.Digest != cutoverRequest(state, state, candidate).ConfirmedDigest {
		t.Fatal("the result does not carry the verified candidate digest")
	}
	ledger, err := readCutoverLedger(state)
	if err != nil {
		t.Fatal(err)
	}
	if ledger.PreviousDigest != currentDigest || ledger.CandidateDigest != result.Digest {
		t.Fatalf("ledger = %+v", ledger)
	}
}

func TestCutoverRefusesAnUnconfirmedCandidate(t *testing.T) {
	state := t.TempDir()
	bin := t.TempDir()
	candidate := goodCandidate(t, bin, "bee-new")
	current := goodCandidate(t, bin, "bee-old")
	digest, err := sha256File(candidate)
	if err != nil {
		t.Fatal(err)
	}
	tampered := digest[:63] + "0"
	if tampered == digest {
		tampered = digest[:63] + "1"
	}
	for _, tc := range []struct {
		name      string
		confirmed string
		candidate string
	}{
		{name: "mismatch", confirmed: tampered, candidate: candidate},
		{name: "empty", confirmed: "", candidate: candidate},
		{name: "malformed", confirmed: "not-a-digest", candidate: candidate},
		{name: "uppercase", confirmed: strings.ToUpper(digest), candidate: candidate},
		{name: "missing", confirmed: digest, candidate: filepath.Join(bin, "absent")},
		{name: "directory", confirmed: digest, candidate: bin},
	} {
		t.Run(tc.name, func(t *testing.T) {
			fake := &cutoverFake{current: current}
			req := CutoverRequest{State: state, Dir: state, Candidate: tc.candidate, ConfirmedDigest: tc.confirmed}
			if _, err := runCutover(context.Background(), req, fake.seams()); err == nil {
				t.Fatal("an unconfirmed candidate was accepted")
			}
			if len(fake.order) != 0 {
				t.Fatalf("an unconfirmed candidate moved the owner: %v", fake.order)
			}
		})
	}
}

func TestCutoverRefusesAFailingSelfTest(t *testing.T) {
	state := t.TempDir()
	bin := t.TempDir()
	candidate := cutoverScript(t, bin, "bee-broken", "exit 1")
	digest, err := sha256File(candidate)
	if err != nil {
		t.Fatal(err)
	}
	silent := cutoverScript(t, bin, "bee-silent", `if [ "$1" = help ]; then exit 0; fi; exit 0`)
	silentDigest, err := sha256File(silent)
	if err != nil {
		t.Fatal(err)
	}
	current := goodCandidate(t, bin, "bee-old")
	for _, tc := range []struct {
		name      string
		candidate string
		confirmed string
	}{
		{name: "exit", candidate: candidate, confirmed: digest},
		{name: "silent", candidate: silent, confirmed: silentDigest},
	} {
		t.Run(tc.name, func(t *testing.T) {
			fake := &cutoverFake{current: current}
			req := CutoverRequest{State: state, Dir: state, Candidate: tc.candidate, ConfirmedDigest: tc.confirmed}
			if _, err := runCutover(context.Background(), req, fake.seams()); err == nil {
				t.Fatal("a candidate that fails its self-test was accepted")
			}
			if len(fake.order) != 0 {
				t.Fatalf("a failing candidate moved the owner: %v", fake.order)
			}
		})
	}
}

func TestCutoverRefusesItsOwnExecutable(t *testing.T) {
	state := t.TempDir()
	bin := t.TempDir()
	current := goodCandidate(t, bin, "bee")
	fake := &cutoverFake{current: current}
	req := cutoverRequest(state, state, current)
	if _, err := runCutover(context.Background(), req, fake.seams()); err == nil {
		t.Fatal("the running executable was accepted as its own replacement")
	}
}

func TestCutoverStopsAnOlderOwnerThroughTheRetainedBinary(t *testing.T) {
	state := t.TempDir()
	bin := t.TempDir()
	candidate := goodCandidate(t, bin, "bee-new")
	current := goodCandidate(t, bin, "bee-old")
	older, err := sha256File(current)
	if err != nil {
		t.Fatal(err)
	}
	retained, _, err := retainCutoverPrevious(state, current)
	if err != nil {
		t.Fatal(err)
	}
	if err := writeCutoverLedger(state, cutoverLedger{
		Previous: retained, PreviousDigest: older, Candidate: current, CandidateDigest: older,
	}); err != nil {
		t.Fatal(err)
	}
	fake := &cutoverFake{current: current, stopErr: incompatibleOwner(state, "")}
	if _, err := runCutover(context.Background(), cutoverRequest(state, state, candidate), fake.seams()); err != nil {
		t.Fatal(err)
	}
	if fake.compatibleWith != retained {
		t.Fatalf("compatible stop used %q, want the retained %q", fake.compatibleWith, retained)
	}
	wantOrder := []string{"stop", "compatible-stop", "release", "start:bee-new"}
	if strings.Join(fake.order, ",") != strings.Join(wantOrder, ",") {
		t.Fatalf("handoff order = %v, want %v", fake.order, wantOrder)
	}
}

func TestCutoverSurfacesManualGuidanceWhenTheOlderStopFails(t *testing.T) {
	state := t.TempDir()
	bin := t.TempDir()
	candidate := goodCandidate(t, bin, "bee-new")
	current := goodCandidate(t, bin, "bee-old")
	retained, _, err := retainCutoverPrevious(state, current)
	if err != nil {
		t.Fatal(err)
	}
	older, err := sha256File(retained)
	if err != nil {
		t.Fatal(err)
	}
	if err := writeCutoverLedger(state, cutoverLedger{
		Previous: retained, PreviousDigest: older, Candidate: current, CandidateDigest: older,
	}); err != nil {
		t.Fatal(err)
	}
	fake := &cutoverFake{current: current,
		stopErr:       incompatibleOwner(state, ""),
		compatibleErr: errors.New("connection refused"),
	}
	_, err = runCutover(context.Background(), cutoverRequest(state, state, candidate), fake.seams())
	if err == nil || !strings.Contains(err.Error(), "kill -TERM") {
		t.Fatalf("failed older stop = %v, want the manual termination guidance", err)
	}
}

func TestCutoverFallsBackToThePreviousBinaryOnFailedBoot(t *testing.T) {
	state := t.TempDir()
	bin := t.TempDir()
	candidate := goodCandidate(t, bin, "bee-new")
	current := goodCandidate(t, bin, "bee-old")
	fake := &cutoverFake{current: current}
	boot := errors.New("owner exited before publishing its rendezvous")
	fake.startErr = func(executable string) error {
		if strings.HasSuffix(executable, "bee-new") {
			return boot
		}
		return nil
	}
	result, err := runCutover(context.Background(), cutoverRequest(state, state, candidate), fake.seams())
	if err == nil || !strings.Contains(err.Error(), "fell back to the previous binary") || !errors.Is(err, boot) {
		t.Fatalf("failed boot = %v, want the boot cause with a fallback report", err)
	}
	wantOrder := []string{"stop", "release", "start:bee-new", "start:" + filepath.Base(result.Previous)}
	if strings.Join(fake.order, ",") != strings.Join(wantOrder, ",") {
		t.Fatalf("handoff order = %v, want %v", fake.order, wantOrder)
	}
	if _, err := os.Stat(result.Previous); err != nil {
		t.Fatalf("the fallback binary was not retained: %v", err)
	}
}

func TestCutoverReportsWhenTheFallbackAlsoFails(t *testing.T) {
	state := t.TempDir()
	bin := t.TempDir()
	candidate := goodCandidate(t, bin, "bee-new")
	current := goodCandidate(t, bin, "bee-old")
	fake := &cutoverFake{current: current}
	fake.startErr = func(string) error { return errors.New("owner exited") }
	_, err := runCutover(context.Background(), cutoverRequest(state, state, candidate), fake.seams())
	if err == nil || !strings.Contains(err.Error(), "retained previous binary failed to boot") || !strings.Contains(err.Error(), "kill -TERM") {
		t.Fatalf("double failure = %v, want both causes with the manual guidance", err)
	}
}

func TestCutoverRollbackBootsTheRetainedBinary(t *testing.T) {
	state := t.TempDir()
	bin := t.TempDir()
	candidate := goodCandidate(t, bin, "bee-new")
	current := goodCandidate(t, bin, "bee-old")
	fake := &cutoverFake{current: current}
	result, err := runCutover(context.Background(), cutoverRequest(state, state, candidate), fake.seams())
	if err != nil {
		t.Fatal(err)
	}
	rollback := &cutoverFake{current: candidate}
	if err := runCutoverRollback(context.Background(), state, state, rollback.seams()); err != nil {
		t.Fatal(err)
	}
	wantOrder := []string{"stop", "release", "start:" + filepath.Base(result.Previous)}
	if strings.Join(rollback.order, ",") != strings.Join(wantOrder, ",") {
		t.Fatalf("rollback order = %v, want %v", rollback.order, wantOrder)
	}
}

func TestCutoverRollbackRefusesATamperedPreviousBinary(t *testing.T) {
	state := t.TempDir()
	bin := t.TempDir()
	candidate := goodCandidate(t, bin, "bee-new")
	current := goodCandidate(t, bin, "bee-old")
	fake := &cutoverFake{current: current}
	if _, err := runCutover(context.Background(), cutoverRequest(state, state, candidate), fake.seams()); err != nil {
		t.Fatal(err)
	}
	ledger, err := readCutoverLedger(state)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(ledger.Previous, []byte("#!/bin/sh\nexit 0\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	rollback := &cutoverFake{current: candidate}
	err = runCutoverRollback(context.Background(), state, state, rollback.seams())
	if err == nil || !strings.Contains(err.Error(), "does not match the cutover ledger") {
		t.Fatalf("tampered rollback = %v, want a ledger mismatch refusal", err)
	}
	if len(rollback.order) != 0 {
		t.Fatalf("a tampered previous binary moved the owner: %v", rollback.order)
	}
}

func TestCutoverRollbackNeedsARecordedCutover(t *testing.T) {
	state := t.TempDir()
	rollback := &cutoverFake{current: "/nonexistent/bee"}
	err := runCutoverRollback(context.Background(), state, state, rollback.seams())
	if err == nil || !strings.Contains(err.Error(), "no native cutover was recorded") {
		t.Fatalf("ledgerless rollback = %v, want a missing-ledger refusal", err)
	}
}

func TestRetainCutoverPreviousKeepsAnExecutableCopy(t *testing.T) {
	state := t.TempDir()
	bin := t.TempDir()
	current := goodCandidate(t, bin, "bee-old")
	retained, digest, err := retainCutoverPrevious(state, current)
	if err != nil {
		t.Fatal(err)
	}
	want, err := sha256File(current)
	if err != nil {
		t.Fatal(err)
	}
	if digest != want {
		t.Fatal("the retained digest does not match the running binary")
	}
	info, err := os.Stat(retained)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm()&0o100 == 0 {
		t.Fatalf("retained mode = %o, want an executable bit", info.Mode().Perm())
	}
	if retained != filepath.Join(ownerDirectory(state), cutoverPreviousName) {
		t.Fatalf("retained path = %q, want the owner-owned slot", retained)
	}
}

func TestIncompatibleOwnerSignalsTheOlderProtocol(t *testing.T) {
	err := incompatibleOwner("state", "")
	if !errors.Is(err, errOlderOwnerProtocol) {
		t.Fatalf("older-owner error = %v, want the typed protocol signal", err)
	}
	for _, want := range []string{"older Bee", "kill -TERM", "state"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("older-owner error = %v, want %q", err, want)
		}
	}
}

func TestCutoverStopFailsFastOnARefusedDrain(t *testing.T) {
	denied := errors.New("DENIED: the host did not grant owner stop")
	seams := (&cutoverFake{stopErr: denied}).seams()
	err := cutoverStop(context.Background(), t.TempDir(), t.TempDir(), seams)
	if !errors.Is(err, denied) {
		t.Fatalf("refused drain = %v, want the refusal without a compatible stop", err)
	}
}
