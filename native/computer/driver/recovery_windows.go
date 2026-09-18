//go:build windows && amd64

// SPDX-License-Identifier: MIT
package driver

import (
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"unsafe"
)

// WTSINFOEX_LEVEL1_W.LogonTime identifies the interactive session's logon,
// unlike the process token's AuthenticationId, which can change under RunAs.
// amd64 layout: outer Level occupies 8 bytes; LogonTime begins at offset 168.
func interactiveLogonTime() (uint64, error) {
	var session uint32
	ok, _, err := kernel32.NewProc("ProcessIdToSessionId").Call(uintptr(os.Getpid()), uintptr(unsafe.Pointer(&session)))
	if ok == 0 {
		return 0, err
	}
	wts := syscall.NewLazyDLL("wtsapi32.dll")
	var info unsafe.Pointer
	var length uint32
	ok, _, err = wts.NewProc("WTSQuerySessionInformationW").Call(0, uintptr(session), 25, uintptr(unsafe.Pointer(&info)), uintptr(unsafe.Pointer(&length)))
	if ok == 0 {
		return 0, err
	}
	defer wts.NewProc("WTSFreeMemory").Call(uintptr(info))
	if info == nil || length < 176 {
		return 0, errors.New("invalid WTS logon information")
	}
	b := unsafe.Slice((*byte)(info), 176)
	if binary.LittleEndian.Uint32(b[:4]) != 1 || binary.LittleEndian.Uint32(b[8:12]) != session {
		return 0, errors.New("WTS logon identity mismatch")
	}
	stamp := binary.LittleEndian.Uint64(b[168:176])
	if stamp == 0 || stamp > 1<<63-1 {
		return 0, errors.New("invalid WTS logon time")
	}
	return stamp, nil
}

func newerInteractiveLogon(previous, current string) bool {
	a, b := strings.Split(previous, ":"), strings.Split(current, ":")
	if len(a) != 4 || len(b) != 4 || a[0] != "windows" || b[0] != "windows" || a[2] == b[2] {
		return false
	}
	old, e1 := strconv.ParseUint(a[3], 16, 64)
	next, e2 := strconv.ParseUint(b[3], 16, 64)
	return e1 == nil && e2 == nil && old > 0 && next > old
}

// VerifyNewLogon is a host recovery check, not an operation that logs anyone
// out. Require a later interactive logon and
// a different token logon identity. A changed slot also requires the old session to be absent. RunAs and lock/unlock do not satisfy it.
// Refuse if any key/button is down; never synthesize releases during recovery.
func VerifyNewLogon(previous string) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	if err := accessible(); err != nil {
		return err
	}
	current, err := sessionIdentity()
	if err != nil {
		return err
	}
	if !newerInteractiveLogon(previous, current) {
		return errors.New("recovery requires a verified replacement interactive logon")
	}
	oldParts, newParts := strings.Split(previous, ":"), strings.Split(current, ":")
	oldID, e1 := strconv.ParseUint(oldParts[1], 10, 32)
	newID, e2 := strconv.ParseUint(newParts[1], 10, 32)
	if e1 != nil || e2 != nil {
		return errors.New("invalid recovery session identifier")
	}
	if oldID != newID {
		exists, e := sessionExists(uint32(oldID))
		if e != nil {
			return e
		}
		if exists {
			return errors.New("previous interactive session still exists")
		}
	}
	for key := 1; key < 256; key++ {
		state, _, _ := user32.NewProc("GetAsyncKeyState").Call(uintptr(key))
		if state&0x8000 != 0 {
			return fmt.Errorf("recovery refused while input is held")
		}
	}
	return accessible()
}

func sessionExists(id uint32) (bool, error) {
	wts := syscall.NewLazyDLL("wtsapi32.dll")
	var entries unsafe.Pointer
	var count uint32
	ok, _, err := wts.NewProc("WTSEnumerateSessionsW").Call(0, 0, 1, uintptr(unsafe.Pointer(&entries)), uintptr(unsafe.Pointer(&count)))
	if ok == 0 {
		return false, err
	}
	defer wts.NewProc("WTSFreeMemory").Call(uintptr(entries))
	if count > 4096 || (count > 0 && entries == nil) {
		return false, errors.New("invalid Windows session inventory")
	}
	type entry struct {
		ID    uint32
		_     uint32
		Name  uintptr
		State uint32
		_     uint32
	}
	for _, item := range unsafe.Slice((*entry)(entries), int(count)) {
		if item.ID == id {
			return true, nil
		}
	}
	return false, nil
}
