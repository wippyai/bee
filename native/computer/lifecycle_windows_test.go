//go:build windows && amd64

// SPDX-License-Identifier: MIT
package computer

import (
	"errors"
	"fmt"
	"os"
	"syscall"
	"testing"
	"time"
	"unsafe"

	"github.com/wippyai/bee/native/computer/driver"
)

func TestRapidDesktopTransition(t *testing.T) {
	if os.Getenv("BEE_COMPUTER_RAPID_TEST") != "1" {
		t.Skip("controlled interactive Windows VM only")
	}
	o := newOwner(t)
	ctx := caller(t, "node", "rapid", o.resource, "control", "observe", "act")
	l, err := o.Open(ctx)
	if err != nil {
		t.Fatal(err)
	}
	frame, png, err := l.Do(ctx, driver.Request{Op: "observe"})
	if err != nil || len(png) == 0 {
		t.Fatalf("initial capture: %v", err)
	}
	u := syscall.NewLazyDLL("user32.dll")
	original, _, err := u.NewProc("OpenInputDesktop").Call(0, 0, 0x0100)
	if original == 0 {
		t.Fatal(err)
	}
	defer u.NewProc("CloseDesktop").Call(original)
	name, _ := syscall.UTF16PtrFromString(fmt.Sprintf("BeeLifecycleProof%d", os.Getpid()))
	alternate, _, err := u.NewProc("CreateDesktopW").Call(uintptr(unsafe.Pointer(name)), 0, 0, 0, 0x01ff, 0)
	if alternate == 0 {
		t.Fatal(err)
	}
	defer u.NewProc("CloseDesktop").Call(alternate)
	defer u.NewProc("SwitchDesktop").Call(original)
	started := time.Now()
	if ok, _, e := u.NewProc("SwitchDesktop").Call(alternate); ok == 0 {
		t.Fatal(e)
	}
	if ok, _, e := u.NewProc("SwitchDesktop").Call(original); ok == 0 {
		t.Fatal(e)
	}
	transition := time.Since(started)
	if transition >= 250*time.Millisecond {
		t.Fatalf("transition %s did not exercise sub-poll interval", transition)
	}
	select {
	case <-l.exited:
	case <-time.After(3 * time.Second):
		t.Fatal("old driver survived quick desktop switch")
	}
	if _, _, err = l.Do(ctx, driver.Request{Op: "observe"}); !errors.Is(err, ErrRetired) {
		t.Fatalf("old lease: %v", err)
	}
	fresh, err := o.Open(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if fresh.endpoint == l.endpoint {
		t.Fatal("reused endpoint after desktop transition")
	}
	result, _, err := fresh.Do(ctx, driver.Request{Op: "act", BasedOn: frame.Frame, Actions: []driver.Action{{Kind: "click", X: 1, Y: 1}}})
	if err != nil || result.Error != "stale or invalid frame" {
		t.Fatalf("old frame accepted after recovery: %+v %v", result, err)
	}
	_, png, err = fresh.Do(ctx, driver.Request{Op: "observe"})
	if err != nil || len(png) == 0 {
		t.Fatalf("fresh capture: %v", err)
	}
	t.Logf("actual away/back=%s; old driver retired, old lease/frame denied, fresh endpoint captured %d bytes", transition, len(png))
}

func TestSessionLock(t *testing.T) {
	if os.Getenv("BEE_COMPUTER_LOCK_TEST") != "1" {
		t.Skip("requires controlled lock and later console sign-in")
	}
	o := newOwner(t)
	ctx := caller(t, "node", "lock", o.resource, "control", "observe")
	l, err := o.Open(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, png, err := l.Do(ctx, driver.Request{Op: "observe"}); err != nil || len(png) == 0 {
		t.Fatalf("before lock: %v", err)
	}
	started := time.Now()
	if ok, _, e := syscall.NewLazyDLL("user32.dll").NewProc("LockWorkStation").Call(); ok == 0 {
		t.Fatal(e)
	}
	select {
	case <-l.exited:
	case <-time.After(5 * time.Second):
		t.Fatal("driver survived workstation lock")
	}
	if _, _, err = l.Do(ctx, driver.Request{Op: "observe"}); !errors.Is(err, ErrRetired) {
		t.Fatalf("old lease after lock: %v", err)
	}
	if _, err = o.Open(ctx); !errors.Is(err, ErrRetired) {
		t.Fatalf("fresh open on locked session: %v", err)
	}
	t.Logf("actual workstation lock retired old endpoint and denied fresh open in %s", time.Since(started))
}
