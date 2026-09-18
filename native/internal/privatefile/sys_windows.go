// SPDX-License-Identifier: MIT

//go:build windows

package privatefile

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

func tryLockFile(file *os.File) (func() error, error) {
	overlapped := &windows.Overlapped{}
	handle := windows.Handle(file.Fd())
	err := windows.LockFileEx(
		handle,
		windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY,
		0,
		1,
		0,
		overlapped,
	)
	if errors.Is(err, windows.ERROR_LOCK_VIOLATION) {
		return nil, errLockBusy
	}
	if err != nil {
		return nil, err
	}
	return func() error {
		return windows.UnlockFileEx(handle, 0, 1, 0, overlapped)
	}, nil
}

func openLockFile(path string) (*os.File, error) {
	path16, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	sa, err := ownerOnlyAttributes()
	if err != nil {
		return nil, err
	}
	handle, err := windows.CreateFile(
		path16,
		windows.GENERIC_READ|windows.GENERIC_WRITE,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE,
		sa,
		windows.OPEN_ALWAYS,
		windows.FILE_ATTRIBUTE_NORMAL|windows.FILE_FLAG_OPEN_REPARSE_POINT,
		0,
	)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(handle), path), nil
}

func openExistingFile(path string) (*os.File, error) {
	path16, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	handle, err := windows.CreateFile(
		path16,
		windows.GENERIC_READ,
		windows.FILE_SHARE_READ,
		nil,
		windows.OPEN_EXISTING,
		windows.FILE_ATTRIBUTE_NORMAL|windows.FILE_FLAG_OPEN_REPARSE_POINT,
		0,
	)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(handle), path), nil
}

// Security attributes apply only when Windows creates the object. Existing
// directories and locks keep their original descriptors and must pass validation.
func ownerOnlyAttributes() (*windows.SecurityAttributes, error) {
	tok, err := windows.OpenCurrentProcessToken()
	if err != nil {
		return nil, err
	}
	defer tok.Close()
	user, err := tok.GetTokenUser()
	if err != nil {
		return nil, err
	}
	sid := user.User.Sid.String()
	sd, err := windows.SecurityDescriptorFromString(fmt.Sprintf("O:%sD:P(A;;FA;;;%s)", sid, sid))
	if err != nil {
		return nil, err
	}
	return &windows.SecurityAttributes{
		Length:             uint32(unsafe.Sizeof(windows.SecurityAttributes{})),
		SecurityDescriptor: sd,
	}, nil
}

func ensurePrivateDir(path string) error {
	if _, err := os.Lstat(path); err == nil {
		return nil // Caller validates without changing existing permissions.
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	sa, err := ownerOnlyAttributes()
	if err != nil {
		return err
	}
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	err = windows.CreateDirectory(p, sa)
	if errors.Is(err, windows.ERROR_ALREADY_EXISTS) {
		return nil
	}
	return err
}

func checkFilePermissions(fi os.FileInfo) error {
	if fi == nil {
		return errors.New("file info is nil")
	}
	if fi.Mode()&os.ModeSymlink != 0 {
		return errors.New("symlink not allowed")
	}
	if !fi.Mode().IsRegular() {
		return fmt.Errorf("file is not a regular file (mode: %s)", fi.Mode())
	}
	return nil
}

func checkFilePathPermissions(path string) error {
	if err := rejectReparsePoint(path); err != nil {
		return err
	}
	fi, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if err := checkFilePermissions(fi); err != nil {
		return err
	}
	return checkWindowsProtectedOwnerACL(path)
}

func checkDirPermissions(dir string) error {
	if err := rejectReparsePoint(dir); err != nil {
		return err
	}
	st, err := os.Lstat(dir)
	if err != nil {
		return fmt.Errorf("stat directory: %w", err)
	}
	if st.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("directory %q is a symlink", dir)
	}
	if !st.IsDir() {
		return fmt.Errorf("path %q is not a directory", dir)
	}
	if err := checkWindowsProtectedOwnerACL(dir); err != nil {
		return fmt.Errorf("directory %q has insecure ACL: %w", dir, err)
	}
	return nil
}

func rejectReparsePoint(path string) error {
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	attrs, err := windows.GetFileAttributes(p)
	if err != nil {
		return err
	}
	if attrs&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		return fmt.Errorf("reparse point refused: %q", path)
	}
	return nil
}

func CheckWindowsProtectedOwnerACL(path string) error {
	return checkWindowsProtectedOwnerACL(path)
}

func checkWindowsProtectedOwnerACL(path string) error {
	tok, err := windows.OpenCurrentProcessToken()
	if err != nil {
		return fmt.Errorf("open current process token: %w", err)
	}
	defer tok.Close()

	tokUser, err := tok.GetTokenUser()
	if err != nil {
		return fmt.Errorf("get token user: %w", err)
	}
	currentUserSID := tokUser.User.Sid

	sd, err := windows.GetNamedSecurityInfo(
		path,
		windows.SE_FILE_OBJECT,
		windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION,
	)
	if err != nil {
		return fmt.Errorf("get security descriptor for %q: %w", path, err)
	}
	if sd == nil {
		return fmt.Errorf("no security descriptor for %q", path)
	}

	owner, _, err := sd.Owner()
	if err != nil {
		return fmt.Errorf("get owner for %q: %w", path, err)
	}
	if !windows.EqualSid(owner, currentUserSID) {
		return fmt.Errorf("path %q is not owned by current user", path)
	}

	ctrl, _, err := sd.Control()
	if err != nil {
		return fmt.Errorf("get security descriptor control for %q: %w", path, err)
	}
	if ctrl&windows.SE_DACL_PRESENT == 0 {
		return fmt.Errorf("path %q has no DACL", path)
	}
	if ctrl&windows.SE_DACL_PROTECTED == 0 {
		return fmt.Errorf("path %q does not have a protected DACL", path)
	}

	dacl, _, err := sd.DACL()
	if err != nil {
		return fmt.Errorf("get DACL for %q: %w", path, err)
	}
	if dacl == nil {
		return fmt.Errorf("path %q has nil DACL", path)
	}

	systemSID, _ := windows.StringToSid("S-1-5-18")

	for i := uint32(0); i < uint32(dacl.AceCount); i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(dacl, i, &ace); err != nil {
			return fmt.Errorf("get ACE %d for %q: %w", i, path, err)
		}
		if ace == nil || ace.Header.AceType != windows.ACCESS_ALLOWED_ACE_TYPE || ace.Header.AceSize < 16 {
			return fmt.Errorf("unsupported ACL entry on %q", path)
		}
		entry := unsafe.Slice((*byte)(unsafe.Pointer(ace)), int(ace.Header.AceSize))
		if entry[8] != 1 || int(entry[9]) > 15 || 16+4*int(entry[9]) > len(entry) {
			return fmt.Errorf("invalid ACL SID on %q", path)
		}
		aceSID := (*windows.SID)(unsafe.Pointer(&ace.SidStart))
		if windows.EqualSid(aceSID, currentUserSID) {
			continue
		}
		if systemSID != nil && windows.EqualSid(aceSID, systemSID) {
			continue
		}
		return fmt.Errorf("insecure DACL on %q: grants access to foreign SID %v", path, aceSID)
	}

	return nil
}

func setOwnerOnlyPermissions(path string) error {
	fi, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if fi.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("cannot set permissions on symlink: %q", path)
	}

	tok, err := windows.OpenCurrentProcessToken()
	if err != nil {
		return fmt.Errorf("open current process token: %w", err)
	}
	defer tok.Close()

	tokUser, err := tok.GetTokenUser()
	if err != nil {
		return fmt.Errorf("get token user: %w", err)
	}
	currentUserSID := tokUser.User.Sid

	sddl := fmt.Sprintf("O:%sD:P(A;;FA;;;%s)", currentUserSID.String(), currentUserSID.String())
	sd, err := windows.SecurityDescriptorFromString(sddl)
	if err != nil {
		return fmt.Errorf("build security descriptor: %w", err)
	}

	dacl, _, err := sd.DACL()
	if err != nil {
		return fmt.Errorf("get DACL from security descriptor: %w", err)
	}
	owner, _, err := sd.Owner()
	if err != nil {
		return fmt.Errorf("get owner from security descriptor: %w", err)
	}

	err = windows.SetNamedSecurityInfo(
		path,
		windows.SE_FILE_OBJECT,
		windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION,
		owner,
		nil,
		dacl,
		nil,
	)
	if err != nil {
		return fmt.Errorf("set protected security info on %q: %w", path, err)
	}
	return nil
}

func syncDirChecked(dir string) error {
	// Windows Win32 API does not support FlushFileBuffers on directory handles.
	// Directory metadata durability is managed by NTFS/ReFS journaling.
	return nil
}

var windowsReservedNames = map[string]struct{}{
	"CON": {}, "PRN": {}, "AUX": {}, "NUL": {},
	"COM1": {}, "COM2": {}, "COM3": {}, "COM4": {}, "COM5": {},
	"COM6": {}, "COM7": {}, "COM8": {}, "COM9": {},
	"LPT1": {}, "LPT2": {}, "LPT3": {}, "LPT4": {}, "LPT5": {},
	"LPT6": {}, "LPT7": {}, "LPT8": {}, "LPT9": {},
}

func validateBasenamePlatform(name string) error {
	if strings.Contains(name, ":") {
		return fmt.Errorf("%w: alternate data stream (colon) not allowed in Windows filename: %q", ErrInvalidName, name)
	}
	if strings.ContainsAny(name, "<>:\"|?*") {
		return fmt.Errorf("%w: invalid character in Windows filename: %q", ErrInvalidName, name)
	}
	for i := 0; i < len(name); i++ {
		if name[i] < 32 {
			return fmt.Errorf("%w: control character in Windows filename: %q", ErrInvalidName, name)
		}
	}
	if strings.HasSuffix(name, " ") || strings.HasSuffix(name, ".") {
		return fmt.Errorf("%w: trailing space or dot in Windows filename: %q", ErrInvalidName, name)
	}
	stem := strings.ToUpper(strings.Split(name, ".")[0])
	if _, ok := windowsReservedNames[stem]; ok {
		return fmt.Errorf("%w: Windows reserved device name: %q", ErrInvalidName, name)
	}
	return nil
}

func sameFilename(a, b string) bool { return strings.EqualFold(a, b) }
