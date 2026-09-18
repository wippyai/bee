//go:build windows && amd64

// SPDX-License-Identifier: MPL-2.0
package driver

import (
	"encoding/binary"
	"errors"
	"fmt"
	"image"
	"os"
	"syscall"
	"unicode/utf16"
	"unsafe"
)

var user32 = syscall.NewLazyDLL("user32.dll")
var gdi32 = syscall.NewLazyDLL("gdi32.dll")
var kernel32 = syscall.NewLazyDLL("kernel32.dll")
var getMetrics = user32.NewProc("GetSystemMetrics")
var sendInput = user32.NewProc("SendInput")
var originX, originY int

const demoText = "bee windows café 中文 😀"

func desktopName(h uintptr) (string, error) {
	b := make([]uint16, 256)
	var needed uint32
	ok, _, e := user32.NewProc("GetUserObjectInformationW").Call(h, 2, uintptr(unsafe.Pointer(&b[0])), uintptr(len(b)*2), uintptr(unsafe.Pointer(&needed)))
	if ok == 0 {
		return "", e
	}
	return syscall.UTF16ToString(b), nil
}
func accessible() error {
	if lifecycleRetired.Load() {
		return errors.New("desktop lifecycle transition; endpoint permanently retired")
	}
	var session uint32
	ok, _, e := kernel32.NewProc("ProcessIdToSessionId").Call(uintptr(os.Getpid()), uintptr(unsafe.Pointer(&session)))
	if ok == 0 {
		return e
	}
	if session == 0 {
		return errors.New("session 0 has no authorized interactive desktop")
	}
	active, _, _ := kernel32.NewProc("WTSGetActiveConsoleSessionId").Call()
	if uint32(active) != session {
		return errors.New("POC requires the active console session")
	}
	// WTS lock state closes the startup gap where a lock notification precedes
	// the input-desktop switch. Windows 11 WTSINFOEX level 1 is 8-byte aligned;
	// SessionFlags is at offset 16 (0 locked, 1 unlocked, -1 unknown).
	wts := syscall.NewLazyDLL("wtsapi32.dll")
	var info unsafe.Pointer
	var length uint32
	ok, _, e = wts.NewProc("WTSQuerySessionInformationW").Call(0, uintptr(session), 25, uintptr(unsafe.Pointer(&info)), uintptr(unsafe.Pointer(&length)))
	if ok == 0 {
		return fmt.Errorf("WTS session state: %w", e)
	}
	defer wts.NewProc("WTSFreeMemory").Call(uintptr(info))
	if info == nil || length < 20 {
		return errors.New("invalid WTS session state")
	}
	state := unsafe.Slice((*byte)(info), 20)
	if binary.LittleEndian.Uint32(state[:4]) != 1 || binary.LittleEndian.Uint32(state[16:20]) != 1 {
		return errors.New("WTS session locked or state unavailable")
	}
	h, _, e := user32.NewProc("OpenInputDesktop").Call(0, 0, 1)
	if h == 0 {
		return fmt.Errorf("input desktop unavailable: %w", e)
	}
	defer user32.NewProc("CloseDesktop").Call(h)
	name, e := desktopName(h)
	if e != nil {
		return e
	}
	tid, _, _ := kernel32.NewProc("GetCurrentThreadId").Call()
	thread, _, _ := user32.NewProc("GetThreadDesktop").Call(tid)
	own, e := desktopName(thread)
	if e != nil {
		return e
	}
	if name != "Default" || own != name {
		return errors.New("input desktop is not the driver's default desktop")
	}
	return nil
}
func openNative() error {
	if err := accessible(); err != nil {
		return err
	}
	ok, _, e := user32.NewProc("SetProcessDpiAwarenessContext").Call(^uintptr(3)) // PER_MONITOR_AWARE_V2
	if ok == 0 {
		return fmt.Errorf("DPI awareness: %w", e)
	}
	if err := startLifecycle(); err != nil {
		stopLifecycle()
		return err
	}
	if err := accessible(); err != nil {
		stopLifecycle()
		return err
	}
	return nil
}
func closeNative()         { stopLifecycle() }
func metric(n uintptr) int { v, _, _ := getMetrics.Call(n); return int(int32(v)) }
func size() (int, int, error) {
	if err := accessible(); err != nil {
		return 0, 0, err
	}
	// First proof supports one display, making image coordinates physical pixels.
	if metric(80) != 1 {
		return 0, 0, errors.New("POC supports one display only")
	}
	w, h := metric(78), metric(79)
	originX, originY = metric(76), metric(77)
	if w <= 1 || h <= 1 || int64(w)*int64(h) > 3840*2160 {
		return 0, 0, errors.New("unsupported display geometry")
	}
	return w, h, nil
}

type bitmapInfo struct {
	Size                         uint32
	Width, Height                int32
	Planes, BitCount             uint16
	Compression, SizeImage       uint32
	XPelsPerMeter, YPelsPerMeter int32
	ClrUsed, ClrImportant        uint32
	Colors                       uint32
}

func captureNative(w, h int) (*image.RGBA, error) {
	dc, _, e := user32.NewProc("GetDC").Call(0)
	if dc == 0 {
		return nil, e
	}
	defer user32.NewProc("ReleaseDC").Call(0, dc)
	mem, _, e := gdi32.NewProc("CreateCompatibleDC").Call(dc)
	if mem == 0 {
		return nil, e
	}
	defer gdi32.NewProc("DeleteDC").Call(mem)
	info := bitmapInfo{Size: 40, Width: int32(w), Height: -int32(h), Planes: 1, BitCount: 32}
	var bits unsafe.Pointer
	bm, _, e := gdi32.NewProc("CreateDIBSection").Call(dc, uintptr(unsafe.Pointer(&info)), 0, uintptr(unsafe.Pointer(&bits)), 0, 0)
	if bm == 0 {
		return nil, e
	}
	defer gdi32.NewProc("DeleteObject").Call(bm)
	old, _, e := gdi32.NewProc("SelectObject").Call(mem, bm)
	if old == 0 || old == ^uintptr(0) {
		return nil, e
	}
	defer gdi32.NewProc("SelectObject").Call(mem, old)
	ok, _, e := gdi32.NewProc("BitBlt").Call(mem, 0, 0, uintptr(w), uintptr(h), dc, uintptr(originX), uintptr(originY), 0x40cc0020)
	if ok == 0 {
		return nil, e
	}
	gdi32.NewProc("GdiFlush").Call()
	src := unsafe.Slice((*byte)(bits), w*h*4)
	im := image.NewRGBA(image.Rect(0, 0, w, h))
	for i := 0; i < len(src); i += 4 {
		im.Pix[i], im.Pix[i+1], im.Pix[i+2], im.Pix[i+3] = src[i+2], src[i+1], src[i], 255
	}
	return im, nil
}
func keySym(k string) uint16 {
	if len(k) == 1 && ((k[0] >= 'A' && k[0] <= 'Z') || (k[0] >= '0' && k[0] <= '9')) {
		return uint16(k[0])
	}
	switch k {
	case "ENTER":
		return 13
	case "TAB":
		return 9
	case "ESC":
		return 27
	case "BACKSPACE":
		return 8
	case "SPACE":
		return 32
	case "HOME":
		return 36
	case "END":
		return 35
	case "LEFT":
		return 37
	case "UP":
		return 38
	case "RIGHT":
		return 39
	case "DOWN":
		return 40
	case "DELETE":
		return 46
	}
	return 0
}
func validate(a Action, w, h int) error {
	point := func(x, y int) bool { return x >= 0 && y >= 0 && x < w && y < h }
	switch a.Kind {
	case "click":
		if !point(a.X, a.Y) {
			return errors.New("point outside frame")
		}
	case "drag":
		if !point(a.X, a.Y) || !point(a.ToX, a.ToY) {
			return errors.New("drag outside frame")
		}
	case "scroll":
		if a.Steps == 0 || a.Steps < -10 || a.Steps > 10 {
			return errors.New("scroll limit")
		}
	case "text":
		if len(utf16.Encode([]rune(a.Text))) > 256 {
			return errors.New("text limit")
		}
		for _, r := range a.Text {
			if r < 32 {
				return errors.New("text contains control characters")
			}
		}
	case "key":
		if _, _, err := shortcut(a.Key); err != nil {
			return errors.New("unsupported key")
		}
	default:
		return errors.New("unknown action")
	}
	return nil
}

type input [40]byte // Windows amd64 INPUT, including alignment padding.
func mouse(flags uint32, x, y, data int) input {
	var b input
	binary.LittleEndian.PutUint32(b[8:], uint32(x))
	binary.LittleEndian.PutUint32(b[12:], uint32(y))
	binary.LittleEndian.PutUint32(b[16:], uint32(data))
	binary.LittleEndian.PutUint32(b[20:], flags)
	return b
}
func keyboard(vk, scan uint16, flags uint32) input {
	var b input
	binary.LittleEndian.PutUint32(b[:], 1)
	binary.LittleEndian.PutUint16(b[8:], vk)
	binary.LittleEndian.PutUint16(b[10:], scan)
	binary.LittleEndian.PutUint32(b[12:], flags)
	return b
}
func execute(a Action) bool {
	w, h, err := size()
	if err != nil {
		return false
	}
	var inputs []input
	move := func(x, y int) { inputs = append(inputs, mouse(0xc001, x*65535/(w-1), y*65535/(h-1), 0)) }
	switch a.Kind {
	case "click":
		move(a.X, a.Y)
		inputs = append(inputs, mouse(2, 0, 0, 0), mouse(4, 0, 0, 0))
	case "drag":
		move(a.X, a.Y)
		inputs = append(inputs, mouse(2, 0, 0, 0))
		for i := 1; i <= 10; i++ {
			move(a.X+(a.ToX-a.X)*i/10, a.Y+(a.ToY-a.Y)*i/10)
		}
		inputs = append(inputs, mouse(4, 0, 0, 0))
	case "scroll":
		inputs = append(inputs, mouse(0x800, 0, 0, -a.Steps*120))
	case "text":
		for _, u := range utf16.Encode([]rune(a.Text)) {
			inputs = append(inputs, keyboard(0, u, 4), keyboard(0, u, 6))
		}
	case "key":
		keys, _, err := shortcut(a.Key)
		if err != nil {
			return false
		}
		inputs = append(inputs, keys...)
	}
	if len(inputs) == 0 {
		return true
	}
	return guardedInput(inputs)
}

// AuthenticationId is the Windows logon LUID, not a reusable WTS session number.
func sessionIdentity() (string, error) {
	var token syscall.Token
	process, err := syscall.GetCurrentProcess()
	if err != nil {
		return "", err
	}
	if err := syscall.OpenProcessToken(process, syscall.TOKEN_QUERY, &token); err != nil {
		return "", err
	}
	defer token.Close()
	var statistics [56]byte
	var needed uint32
	if err := syscall.GetTokenInformation(token, 10, &statistics[0], uint32(len(statistics)), &needed); err != nil {
		return "", err
	}
	var session uint32
	ok, _, err := kernel32.NewProc("ProcessIdToSessionId").Call(uintptr(os.Getpid()), uintptr(unsafe.Pointer(&session)))
	if ok == 0 {
		return "", err
	}
	logon, err := interactiveLogonTime()
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("windows:%d:%x:%x", session, statistics[8:16], logon), nil
}
