//go:build windows && amd64 && computerfault

// SPDX-License-Identifier: MIT
package computer

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"syscall"
	"testing"
	"time"
	"unsafe"

	"github.com/wippyai/bee/native/computer/driver"
	"golang.org/x/sys/windows"
)

func TestOwnerNativeInputInterruption(t *testing.T) {
	if os.Getenv("BEE_COMPUTER_INPUT_TEST") != "1" {
		t.Skip("isolated interactive Windows VM only")
	}
	for _, mode := range []string{"caller_cancel", "driver_kill", "desktop_switch"} {
		t.Run(mode, func(t *testing.T) {
			runtime.LockOSThread()
			defer runtime.UnlockOSThread()
			held := func() bool { v, _, _ := user32.NewProc("GetAsyncKeyState").Call(0xa2); return v&0x8000 != 0 }
			if held() {
				t.Fatal("Control already held")
			}
			dir := t.TempDir()
			guardPID := filepath.Join(dir, "guard.pid")
			injectPID := filepath.Join(dir, "inject.pid")
			t.Setenv("BEE_OWNER_INPUT_FAULT", "1")
			t.Setenv("BEE_OWNER_GUARD_PID", guardPID)
			t.Setenv("BEE_OWNER_INJECT_PID", injectPID)
			o := newOwner(t)
			ctx := caller(t, "node", "fault", o.resource, "control", "observe", "act")
			l, err := o.Open(ctx)
			if err != nil {
				t.Fatal(err)
			}
			frame, _, err := l.Do(ctx, driver.Request{Op: "observe"})
			if err != nil || frame.Error != "" {
				t.Fatalf("observe: %+v %v", frame, err)
			}
			op, cancel := context.WithCancel(ctx)
			defer cancel()
			result := make(chan error, 1)
			go func() {
				_, _, e := l.Do(op, driver.Request{Op: "act", BasedOn: frame.Frame, Actions: []driver.Action{{Kind: "key", Key: "CTRL+A"}}})
				result <- e
			}()
			// Outer cleanup is never credited to the production path.
			defer func() {
				cancel()
				l.cmd.Process.Kill()
				var b [40]byte
				binary.LittleEndian.PutUint32(b[:], 1)
				binary.LittleEndian.PutUint16(b[8:], 0xa2)
				binary.LittleEndian.PutUint32(b[12:], 2)
				user32.NewProc("SendInput").Call(1, uintptr(unsafe.Pointer(&b[0])), 40)
			}()
			waitOwnerEffect(t, held)
			openLive := func(path string) windows.Handle {
				var id int
				waitOwnerEffect(t, func() bool {
					b, e := os.ReadFile(path)
					if e != nil {
						return false
					}
					id, e = strconv.Atoi(string(b))
					return e == nil && id > 0
				})
				h, e := windows.OpenProcess(windows.SYNCHRONIZE, false, uint32(id))
				if e != nil {
					t.Fatal(e)
				}
				status, e := windows.WaitForSingleObject(h, 0)
				if e != nil || status != uint32(windows.WAIT_TIMEOUT) {
					windows.CloseHandle(h)
					t.Fatalf("process not live before fault: %d %v", status, e)
				}
				return h
			}
			guard, injector := openLive(guardPID), openLive(injectPID)
			defer windows.CloseHandle(guard)
			defer windows.CloseHandle(injector)
			started := time.Now()
			switch mode {
			case "caller_cancel":
				cancel()
			case "driver_kill":
				if err = l.cmd.Process.Kill(); err != nil {
					t.Fatal(err)
				}
			case "desktop_switch":
				original, _, e := user32.NewProc("OpenInputDesktop").Call(0, 0, 0x100)
				if original == 0 {
					t.Fatal(e)
				}
				defer user32.NewProc("CloseDesktop").Call(original)
				name, _ := syscall.UTF16PtrFromString(fmt.Sprintf("BeeInputFault%d", os.Getpid()))
				alternate, _, e := user32.NewProc("CreateDesktopW").Call(uintptr(unsafe.Pointer(name)), 0, 0, 0, 0x1ff, 0)
				if alternate == 0 {
					t.Fatal(e)
				}
				defer user32.NewProc("CloseDesktop").Call(alternate)
				defer user32.NewProc("SwitchDesktop").Call(original)
				if ok, _, e := user32.NewProc("SwitchDesktop").Call(alternate); ok == 0 {
					t.Fatal(e)
				}
				if ok, _, e := user32.NewProc("SwitchDesktop").Call(original); ok == 0 {
					t.Fatal(e)
				}
			}
			select {
			case err = <-result:
				if !errors.Is(err, ErrUncertain) {
					t.Fatalf("interrupted input: %v", err)
				}
			case <-time.After(6 * time.Second):
				t.Fatal("owner input did not finish")
			}
			for _, h := range []windows.Handle{guard, injector} {
				status, e := windows.WaitForSingleObject(h, 3000)
				if e != nil || status != windows.WAIT_OBJECT_0 {
					t.Fatalf("input process survived: %d %v", status, e)
				}
			}
			if mode != "desktop_switch" {
				waitOwnerEffect(t, func() bool { return !held() })
			}
			stillHeld := held()
			if err = o.Revoke(ctx); !errors.Is(err, ErrRecovery) {
				t.Fatalf("revoke claimed clean state: %v", err)
			}
			replacement := &Owner{executable: o.executable, node: o.node, resource: o.resource, recovery: o.recovery}
			if _, err = replacement.Open(ctx); !errors.Is(err, ErrRecovery) {
				t.Fatalf("replacement admitted: %v", err)
			}
			t.Logf("real Control-down; actual %s; guard/injector exited; held_after=%v; owner returned uncertain and replacement denied after %s", mode, stillHeld, time.Since(started))
		})
	}
}
