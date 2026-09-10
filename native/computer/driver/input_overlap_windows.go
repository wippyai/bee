//go:build windows && amd64

// SPDX-License-Identifier: MIT
package driver

import (
	"crypto/rand"
	"encoding/binary"
	"errors"
	"sync/atomic"
	"syscall"
	"unsafe"
)

var transactionCookie atomic.Uint64
var foreignInput atomic.Bool
var foreignPhysical atomic.Bool
var foreignInputWake = make(chan struct{}, 1)

// Tag only this transaction's native events. This is provenance for local
// collision handling, not an authorization token against same-account code.
func tagTransaction(batch []input) error {
	var random [8]byte
	if _, err := rand.Read(random[:]); err != nil {
		return err
	}
	cookie := binary.LittleEndian.Uint64(random[:])
	if cookie == 0 {
		return errors.New("invalid transaction cookie")
	}
	transactionCookie.Store(cookie)
	for i := range batch {
		if binary.LittleEndian.Uint32(batch[i][:4]) == 1 {
			binary.LittleEndian.PutUint64(batch[i][24:32], cookie)
		} else {
			binary.LittleEndian.PutUint64(batch[i][32:40], cookie)
		}
	}
	return nil
}

func ownedInput(injected bool, cookie uint64) bool {
	return injected && cookie != 0 && cookie == transactionCookie.Load()
}

// Install on the existing dedicated lifecycle message-pump thread. Hooks
// record only a collision bit: no key identities, text or pointer history.
// Foreign events always pass onward. Only our tagged events are suppressed
// after a collision; physical input is never blocked.
func watchInputOverlap() (func(), error) {
	if transactionCookie.Load() == 0 {
		return func() {}, nil
	} // Capture-only driver.
	conflict := func(physical bool) {
		if physical {
			foreignPhysical.Store(true)
		}
		foreignInput.Store(true)
		select {
		case foreignInputWake <- struct{}{}:
		default:
		}
	}
	keyboardCallback := syscall.NewCallback(func(code int32, wp uintptr, lp unsafe.Pointer) uintptr {
		if code >= 0 && lp != nil {
			b := unsafe.Slice((*byte)(lp), 24)
			if ownedInput(binary.LittleEndian.Uint32(b[8:12])&0x10 != 0, binary.LittleEndian.Uint64(b[16:24])) {
				if foreignInput.Load() {
					return 1
				} // suppress only our events after collision
			} else {
				conflict(binary.LittleEndian.Uint32(b[8:12])&0x10 == 0)
			}
		}
		result, _, _ := user32.NewProc("CallNextHookEx").Call(0, uintptr(code), wp, uintptr(lp))
		return result
	})
	mouseCallback := syscall.NewCallback(func(code int32, wp uintptr, lp unsafe.Pointer) uintptr {
		if code >= 0 && lp != nil {
			b := unsafe.Slice((*byte)(lp), 32)
			if ownedInput(binary.LittleEndian.Uint32(b[12:16])&1 != 0, binary.LittleEndian.Uint64(b[24:32])) {
				if foreignInput.Load() {
					return 1
				}
			} else {
				conflict(binary.LittleEndian.Uint32(b[12:16])&1 == 0)
			}
		}
		result, _, _ := user32.NewProc("CallNextHookEx").Call(0, uintptr(code), wp, uintptr(lp))
		return result
	})
	instance, _, err := kernel32.NewProc("GetModuleHandleW").Call(0)
	if instance == 0 {
		return nil, err
	}
	keyboard, _, err := user32.NewProc("SetWindowsHookExW").Call(13, keyboardCallback, instance, 0)
	if keyboard == 0 {
		return nil, err
	}
	mouse, _, err := user32.NewProc("SetWindowsHookExW").Call(14, mouseCallback, instance, 0)
	if mouse == 0 {
		user32.NewProc("UnhookWindowsHookEx").Call(keyboard)
		return nil, err
	}
	return func() {
		user32.NewProc("UnhookWindowsHookEx").Call(mouse)
		user32.NewProc("UnhookWindowsHookEx").Call(keyboard)
	}, nil
}
