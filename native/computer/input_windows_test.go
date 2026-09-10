//go:build windows && amd64

// SPDX-License-Identifier: MIT
package computer

import (
	"errors"
	"github.com/wippyai/bee/native/computer/driver"
	"os"
	"path/filepath"
	"runtime"
	"syscall"
	"testing"
	"time"
	"unsafe"
)

func waitOwnerEffect(t *testing.T, predicate func() bool) {
	t.Helper()
	until := time.Now().Add(2 * time.Second)
	for !predicate() {
		if time.Now().After(until) {
			t.Fatal("native effect checkpoint timed out")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

var user32 = syscall.NewLazyDLL("user32.dll")

func TestOwnerNativeShortcutAndRecovery(t *testing.T) {
	if os.Getenv("BEE_COMPUTER_INPUT_TEST") != "1" {
		t.Skip("isolated interactive Windows desktop only")
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(t.TempDir(), "seat")
	o, err := New(exe, "node", "bee.computer:console", dir)
	if err != nil {
		t.Fatal(err)
	}
	ctx := caller(t, "node", "real-input", o.resource, "control", "observe", "act")
	defer o.Stop(ctx)
	lease, err := o.Open(ctx)
	if err != nil {
		t.Fatal(err)
	}
	execute := func(a driver.Action) bool {
		frame, _, err := lease.Do(ctx, driver.Request{Op: "observe"})
		if err != nil || frame.Error != "" {
			t.Fatalf("observe: %+v %v", frame, err)
		}
		result, _, err := lease.Do(ctx, driver.Request{Op: "act", BasedOn: frame.Frame, Actions: []driver.Action{a}})
		if err != nil || result.Error != "" || len(result.Outcomes) != 1 || result.Outcomes[0] != "injected" {
			t.Fatalf("input: %+v %v", result, err)
		}
		if err = o.recovery.available(ctx); err != nil {
			t.Fatalf("completed transaction remains pending: %v", err)
		}
		return true
	}
	type created struct {
		hwnd uintptr
		err  error
	}
	ready := make(chan created, 1)
	stop, done := make(chan struct{}), make(chan struct{})
	go func() {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
		defer close(done)
		class, _ := syscall.UTF16PtrFromString("EDIT")
		title, _ := syscall.UTF16PtrFromString("original text")
		hwnd, _, err := user32.NewProc("CreateWindowExW").Call(0, uintptr(unsafe.Pointer(class)), uintptr(unsafe.Pointer(title)), 0x10cf0004, 100, 100, 500, 300, 0, 0, 0, 0)
		if hwnd == 0 {
			ready <- created{err: err}
			return
		}
		defer user32.NewProc("DestroyWindow").Call(hwnd)
		if ok, _, _ := user32.NewProc("SetForegroundWindow").Call(hwnd); ok == 0 {
			ready <- created{err: errors.New("fixture foreground denied")}
			return
		}
		user32.NewProc("SetFocus").Call(hwnd)
		ready <- created{hwnd: hwnd}
		var aligned [6]uint64 // amd64 MSG, including 8-byte alignment.
		for {
			select {
			case <-stop:
				return
			default:
			}
			for {
				ok, _, _ := user32.NewProc("PeekMessageW").Call(uintptr(unsafe.Pointer(&aligned[0])), 0, 0, 0, 1)
				if ok == 0 {
					break
				}
				user32.NewProc("TranslateMessage").Call(uintptr(unsafe.Pointer(&aligned[0])))
				user32.NewProc("DispatchMessageW").Call(uintptr(unsafe.Pointer(&aligned[0])))
			}
			time.Sleep(time.Millisecond)
		}
	}()
	defer func() { close(stop); <-done }()
	fixture := <-ready
	if fixture.err != nil {
		t.Fatal(fixture.err)
	}
	foreground, _, _ := user32.NewProc("GetForegroundWindow").Call()
	if foreground != fixture.hwnd {
		t.Fatal("fixture is not foreground")
	}
	for _, key := range []string{"CTRL+HOME", "CTRL+SHIFT+END"} {
		if !execute(driver.Action{Kind: "key", Key: key}) {
			t.Fatalf("shortcut injection failed: %s", key)
		}
	}
	waitOwnerEffect(t, func() bool {
		var first, last uint32
		user32.NewProc("SendMessageW").Call(fixture.hwnd, 0xb0, uintptr(unsafe.Pointer(&first)), uintptr(unsafe.Pointer(&last)))
		return first == 0 && last == 13
	})
	if !execute(driver.Action{Kind: "text", Text: "replaced café"}) {
		t.Fatal("replacement injection failed")
	}
	waitOwnerEffect(t, func() bool {
		var text [128]uint16
		user32.NewProc("SendMessageW").Call(fixture.hwnd, 13, uintptr(len(text)), uintptr(unsafe.Pointer(&text[0])))
		return syscall.UTF16ToString(text[:]) == "replaced café"
	})
	t.Log("native EDIT selection covered all 13 original characters; Unicode input replaced them exactly")

	if err := o.Revoke(ctx); err != nil {
		t.Fatal(err)
	}
	replacement, err := New(exe, "node", o.resource, dir)
	if err != nil {
		t.Fatal(err)
	}
	defer replacement.Stop(ctx)
	if _, err = replacement.Open(ctx); err != nil {
		t.Fatalf("clean transaction prevented replacement: %v", err)
	}
	t.Log("actual owner/driver/guardian input completed; matching recovery record cleared; replacement owner admitted")
}
