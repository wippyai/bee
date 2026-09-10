//go:build windows && amd64

// SPDX-License-Identifier: MIT
package driver

import (
	"errors"
	"fmt"
	"os"
	"runtime"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"
)

var lifecycleRetired atomic.Bool
var lifecycleThread uintptr
var lifecycleDone chan struct{}

type windowClass struct {
	Size, Style                                                        uint32
	Procedure                                                          uintptr
	ClassExtra, WindowExtra                                            int32
	Instance, Icon, Cursor, Background, MenuName, ClassName, SmallIcon uintptr
}

type windowMessage struct {
	Window         uintptr
	Message        uint32
	_              uint32
	WParam, LParam uintptr
	Time           uint32
	X, Y           int32
	Private        uint32
}

// A dedicated message-pump thread records edges permanently. The input thread
// retains synchronous accessibility checks; notifications supplement them.
func startLifecycle() error {
	var session uint32
	ok, _, err := kernel32.NewProc("ProcessIdToSessionId").Call(uintptr(os.Getpid()), uintptr(unsafe.Pointer(&session)))
	if ok == 0 {
		return err
	}
	ready := make(chan error, 1)
	lifecycleDone = make(chan struct{})
	go func() {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
		defer close(lifecycleDone)
		defer lifecycleRetired.Store(true)
		lifecycleThread, _, _ = kernel32.NewProc("GetCurrentThreadId").Call()
		instance, _, e := kernel32.NewProc("GetModuleHandleW").Call(0)
		if instance == 0 {
			ready <- e
			return
		}
		name, _ := syscall.UTF16PtrFromString(fmt.Sprintf("BeeComputerLifecycle%d", os.Getpid()))
		procedure := syscall.NewCallback(func(hwnd uintptr, msg uint32, wp, lp uintptr) uintptr {
			switch msg {
			case 0x02b1: // WM_WTSSESSION_CHANGE: any selected-session transition.
				if uint32(lp) == session {
					lifecycleRetired.Store(true)
				}
			case 0x007e: // WM_DISPLAYCHANGE invalidates capture geometry.
				lifecycleRetired.Store(true)
			case 0x0218: // WM_POWERBROADCAST: suspend/resume invalidates the endpoint.
				if wp == 4 || wp == 7 || wp == 18 {
					lifecycleRetired.Store(true)
				}
			}
			result, _, _ := user32.NewProc("DefWindowProcW").Call(hwnd, uintptr(msg), wp, lp)
			return result
		})
		class := windowClass{Procedure: procedure, Instance: instance, ClassName: uintptr(unsafe.Pointer(name))}
		class.Size = uint32(unsafe.Sizeof(class))
		atom, _, e := user32.NewProc("RegisterClassExW").Call(uintptr(unsafe.Pointer(&class)))
		if atom == 0 {
			ready <- e
			return
		}
		defer user32.NewProc("UnregisterClassW").Call(uintptr(unsafe.Pointer(name)), instance)
		// Hidden top-level window receives WTS and display/power broadcasts.
		window, _, e := user32.NewProc("CreateWindowExW").Call(0, uintptr(unsafe.Pointer(name)), uintptr(unsafe.Pointer(name)), 0, 0, 0, 0, 0, 0, 0, instance, 0)
		if window == 0 {
			ready <- e
			return
		}
		defer user32.NewProc("DestroyWindow").Call(window)
		wts := syscall.NewLazyDLL("wtsapi32.dll")
		ok, _, e = wts.NewProc("WTSRegisterSessionNotification").Call(window, 0) // NOTIFY_FOR_THIS_SESSION
		if ok == 0 {
			ready <- e
			return
		}
		defer wts.NewProc("WTSUnRegisterSessionNotification").Call(window)
		// WTS does not report every input-desktop switch (for example UAC).
		eventCallback := syscall.NewCallback(func(hook uintptr, event uint32, hwnd uintptr, object, child int32, thread, stamp uint32) uintptr {
			if event == 0x0020 {
				lifecycleRetired.Store(true)
			} // EVENT_SYSTEM_DESKTOPSWITCH
			return 0
		})
		hook, _, e := user32.NewProc("SetWinEventHook").Call(0x0020, 0x0020, 0, eventCallback, 0, 0, 0) // OUTOFCONTEXT
		if hook == 0 {
			ready <- e
			return
		}
		defer user32.NewProc("UnhookWinEvent").Call(hook)
		stopOverlap, e := watchInputOverlap()
		if e != nil {
			ready <- e
			return
		}
		defer stopOverlap()
		ready <- nil
		var msg windowMessage
		for {
			status, _, _ := user32.NewProc("GetMessageW").Call(uintptr(unsafe.Pointer(&msg)), 0, 0, 0)
			if int32(status) <= 0 {
				return
			}
			user32.NewProc("TranslateMessage").Call(uintptr(unsafe.Pointer(&msg)))
			user32.NewProc("DispatchMessageW").Call(uintptr(unsafe.Pointer(&msg)))
		}
	}()
	if err := <-ready; err != nil {
		<-lifecycleDone
		return err
	}
	if lifecycleRetired.Load() {
		return errors.New("desktop lifecycle retired during startup")
	}
	return nil
}

func stopLifecycle() {
	if lifecycleDone == nil {
		return
	}
	user32.NewProc("PostThreadMessageW").Call(lifecycleThread, 0x0012, 0, 0) // WM_QUIT
	select {
	case <-lifecycleDone:
	case <-time.After(time.Second):
	}
}
