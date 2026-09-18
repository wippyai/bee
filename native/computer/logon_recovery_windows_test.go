//go:build windows && amd64

// SPDX-License-Identifier: MIT
package computer

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/wippyai/bee/native/computer/driver"
)

func TestRecoveryRequiresActualNewLogon(t *testing.T) {
	o := newOwner(t)
	ctx := caller(t, "node", "same-logon", o.resource, "control", "observe")
	l, err := o.Open(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = o.recovery.begin(ctx, l.session); err != nil {
		t.Fatal(err)
	}
	if err = o.Revoke(ctx); !errors.Is(err, ErrRecovery) {
		t.Fatal(err)
	}
	if err = o.RecoverAfterLogon(ctx); !errors.Is(err, ErrDenied) {
		t.Fatalf("control scope reset quarantine: %v", err)
	}
	recovery := caller(t, "node", "host-recovery", o.resource, "recover")
	if err = o.RecoverAfterLogon(recovery); !errors.Is(err, ErrRecovery) {
		t.Fatalf("same logon cleared quarantine: %v", err)
	}
	if err = o.recovery.available(ctx); !errors.Is(err, ErrRecovery) {
		t.Fatal("failed verification changed pending state")
	}
	t.Logf("same-logon recovery denied; record retained; interactive identity=%s", l.session)
}

// Two separately scheduled runs around an externally verified actual logoff.
// The fixed host-selected directory retains the old marker; no test deletes it.
func TestRecoveryAcrossRealLogon(t *testing.T) {
	phase := os.Getenv("BEE_TEST_LOGON_PHASE")
	if phase != "seed" && phase != "recover" {
		t.Skip("explicit two-logon VM experiment only")
	}
	dir := os.Getenv("BEE_TEST_LOGON_DIRECTORY")
	if !filepath.IsAbs(dir) {
		t.Fatal("host-selected absolute recovery directory required")
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	o, err := New(exe, "node", "bee.computer:console", dir)
	if err != nil {
		t.Fatal(err)
	}
	ctx := caller(t, "node", "host-logon", o.resource, "control", "observe", "recover")
	defer o.Stop(ctx)
	if phase == "seed" {
		l, err := o.Open(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if _, err = o.recovery.begin(ctx, l.session); err != nil {
			t.Fatal(err)
		}
		if err = o.Revoke(ctx); !errors.Is(err, ErrRecovery) {
			t.Fatal(err)
		}
		if err = o.RecoverAfterLogon(ctx); !errors.Is(err, ErrRecovery) {
			t.Fatalf("seed logon unexpectedly recovered: %v", err)
		}
		t.Logf("retained pending marker in old interactive logon: %s", l.session)
		return
	}
	if _, err = o.Open(ctx); !errors.Is(err, ErrRecovery) {
		t.Fatalf("replacement bypassed explicit recovery: %v", err)
	}
	if err = o.RecoverAfterLogon(ctx); err != nil {
		t.Fatal(err)
	}
	l, err := o.Open(ctx)
	if err != nil {
		t.Fatal(err)
	}
	frame, data, err := l.Do(ctx, driver.Request{Op: "observe"})
	if err != nil || len(data) == 0 || frame.Error != "" {
		t.Fatalf("fresh recovered capture: %+v %v", frame, err)
	}
	t.Logf("OS-verified replacement logon cleared quarantine and captured %d bytes: %s", len(data), l.session)
}
