//go:build windows && amd64

// SPDX-License-Identifier: MIT
package driver

import (
	"errors"
	"os"
	"runtime"
	"syscall"
	"testing"
	"time"
	"unsafe"
)

func waitEffect(t *testing.T, predicate func() bool) {
	t.Helper()
	until := time.Now().Add(2 * time.Second)
	for !predicate() {
		if time.Now().After(until) {
			t.Fatal("native effect checkpoint timed out")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestNativeShortcutEffects(t *testing.T) {
	if os.Getenv("BEE_COMPUTER_INPUT_TEST") != "1" {
		t.Skip("isolated interactive Windows desktop only")
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
		if !execute(Action{Kind: "key", Key: key}) {
			t.Fatalf("shortcut injection failed: %s", key)
		}
	}
	waitEffect(t, func() bool {
		var first, last uint32
		user32.NewProc("SendMessageW").Call(fixture.hwnd, 0xb0, uintptr(unsafe.Pointer(&first)), uintptr(unsafe.Pointer(&last)))
		return first == 0 && last == 13
	})
	if !execute(Action{Kind: "text", Text: "replaced café"}) {
		t.Fatal("replacement injection failed")
	}
	waitEffect(t, func() bool {
		var text [128]uint16
		user32.NewProc("SendMessageW").Call(fixture.hwnd, 13, uintptr(len(text)), uintptr(unsafe.Pointer(&text[0])))
		return syscall.UTF16ToString(text[:]) == "replaced café"
	})
	t.Log("native EDIT selection covered all 13 original characters; Unicode input replaced them exactly")

	held := func(key uint16) bool {
		state, _, _ := user32.NewProc("GetAsyncKeyState").Call(uintptr(key))
		return state&0x8000 != 0
	}
	batch, _, _ := shortcut("CTRL+A")
	releases, _ := releasePlan(batch)
	send := func(items []input) int {
		n, _, _ := sendInput.Call(uintptr(len(items)), uintptr(unsafe.Pointer(&items[0])), 40)
		return int(n)
	}
	defer send(releases) // emergency fallback, never used to satisfy the assertion.
	calls, retired, observedDown := 0, false, false
	if submitTransaction(batch, held, func(items []input) int {
		calls++
		if calls == 1 {
			n := send(items[:1]) // Actual Control-down; simulate a returned partial batch.
			waitEffect(t, func() bool { return held(0xa2) })
			observedDown = true
			return n
		}
		return send(items)
	}, func() bool { return accessible() == nil }, func() { retired = true }) {
		t.Fatal("partial injection reported success")
	}
	waitEffect(t, func() bool { return !held(0xa2) })
	if !observedDown || !retired || calls != 2 {
		t.Fatalf("down=%v retired=%v calls=%d", observedDown, retired, calls)
	}
	t.Log("real Control-down prefix observed; production transaction path released it, reported uncertainty, and requested retirement")
}
