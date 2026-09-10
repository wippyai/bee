// SPDX-License-Identifier: MIT
package computer

import (
	"context"
	"errors"
	"github.com/wippyai/bee/native/computer/driver"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

func TestRecoverySurvivesProcessExit(t *testing.T) {
	if dir := os.Getenv("BEE_TEST_RECOVERY_CRASH_DIR"); dir != "" {
		s, err := newRecovery(dir, "node", "console")
		if err != nil {
			os.Exit(2)
		}
		if _, err = s.begin(context.Background(), "fixture-session"); err != nil {
			os.Exit(3)
		}
		os.Exit(17) // Real process exit; no defer clears the committed marker.
	}
	dir := filepath.Join(t.TempDir(), "seat")
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	c := exec.Command(exe, "-test.run=^TestRecoverySurvivesProcessExit$")
	c.Env = append(os.Environ(), "BEE_TEST_RECOVERY_CRASH_DIR="+dir)
	if err = c.Run(); err == nil || c.ProcessState.ExitCode() != 17 {
		t.Fatalf("crash fixture: %v", err)
	}
	s, err := newRecovery(dir, "node", "console")
	if err != nil {
		t.Fatal(err)
	}
	if err = s.available(context.Background()); !errors.Is(err, ErrRecovery) {
		t.Fatalf("replacement admitted: %v", err)
	}
	if _, err = s.begin(context.Background(), "fixture-session"); !errors.Is(err, ErrRecovery) {
		t.Fatalf("replacement overwrote pending: %v", err)
	}
}

func TestRecoveryExactCompletionAndBinding(t *testing.T) {
	ctx := context.Background()
	dir := filepath.Join(t.TempDir(), "seat")
	s, err := newRecovery(dir, "node", "console")
	if err != nil {
		t.Fatal(err)
	}
	token, err := s.begin(ctx, "fixture-session")
	if err != nil {
		t.Fatal(err)
	}
	if err = s.complete(ctx, "wrong"); !errors.Is(err, ErrRecovery) {
		t.Fatal(err)
	}
	other, err := newRecovery(dir, "node", "other-seat")
	if err != nil {
		t.Fatal(err)
	}
	if err = other.available(ctx); !errors.Is(err, ErrRecovery) {
		t.Fatalf("resource rebinding: %v", err)
	}
	if err = s.complete(ctx, token); err != nil {
		t.Fatal(err)
	}
	if err = s.complete(ctx, token); !errors.Is(err, ErrRecovery) {
		t.Fatalf("completion replay: %v", err)
	}
	if err = s.available(ctx); err != nil {
		t.Fatal(err)
	}
}

func TestRecoveryRejectsCorruptState(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "seat")
	state, e := newRecovery(dir, "node", "console")
	if e != nil {
		t.Fatal(e)
	}
	if e = state.available(context.Background()); e != nil {
		t.Fatal(e)
	}
	if err := os.WriteFile(filepath.Join(dir, "recovery.json"), []byte(`{"revision":1,"pending":"broken"}`), 0600); err != nil {
		t.Fatal(err)
	}
	s, err := newRecovery(dir, "node", "console")
	if err != nil {
		t.Fatal(err)
	}
	if err = s.available(context.Background()); err == nil {
		t.Fatal("corrupt state accepted")
	}
}

func TestInterruptedOwnerQuarantinesReplacement(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("stalled transport fixture; actual Windows guard integration has separate acceptance")
	}
	o := newOwner(t)
	ctx := caller(t, "node", "interrupted", o.resource, "control", "observe", "act")
	l, err := o.Open(ctx)
	if err != nil {
		t.Fatal(err)
	}
	op, cancel := context.WithTimeout(ctx, 50*time.Millisecond)
	defer cancel()
	_, _, err = l.Do(op, driver.Request{Op: "act", Actions: []driver.Action{{Kind: "text", Text: "fixture-stall"}}})
	if !errors.Is(err, ErrUncertain) {
		t.Fatal(err)
	}
	<-l.exited
	if err = o.Revoke(ctx); !errors.Is(err, ErrRecovery) {
		t.Fatalf("revoke reported cleanup: %v", err)
	}
	replacement := &Owner{executable: o.executable, node: o.node, resource: o.resource, recovery: o.recovery}
	if _, err = replacement.Open(ctx); !errors.Is(err, ErrRecovery) {
		t.Fatalf("new owner admitted: %v", err)
	}
}
