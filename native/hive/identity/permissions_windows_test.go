// SPDX-License-Identifier: MIT
//go:build windows

package identity

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/wippyai/bee/native/internal/privatefile"
	"golang.org/x/sys/windows"
)

func TestWindowsSecureCreationAndReopen(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "identity")
	first, err := OpenOrCreate(context.Background(), dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{dir, filepath.Join(dir, LockFileName), filepath.Join(dir, IdentityFileName)} {
		if err := privatefile.CheckWindowsProtectedOwnerACL(path); err != nil {
			t.Fatal(err)
		}
	}
	second, err := OpenOrCreate(context.Background(), dir)
	if err != nil {
		t.Fatal(err)
	}
	if first.ID() != second.ID() {
		t.Fatal("identity changed on reopen")
	}
}

func TestWindowsExistingDirectoryACLIsNotRepaired(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "existing")
	if err := privatefile.EnsurePrivateDir(dir); err != nil {
		t.Fatal(err)
	}
	// Deliberately grant Everyone access to a disposable fixture.
	sd, err := windows.SecurityDescriptorFromString("D:P(A;;FA;;;WD)")
	if err != nil {
		t.Fatal(err)
	}
	acl, _, err := sd.DACL()
	if err != nil {
		t.Fatal(err)
	}
	if err := windows.SetNamedSecurityInfo(dir, windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION,
		nil, nil, acl, nil); err != nil {
		t.Fatal(err)
	}
	readACL := func() string {
		t.Helper()
		sd, err := windows.GetNamedSecurityInfo(dir, windows.SE_FILE_OBJECT,
			windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
		if err != nil {
			t.Fatal(err)
		}
		return sd.String()
	}
	before := readACL()
	if _, err := OpenOrCreate(context.Background(), dir); err == nil {
		t.Fatal("insecure ACL accepted")
	}
	if readACL() != before {
		t.Fatal("validation changed existing ACL")
	}
	if _, err := os.Stat(filepath.Join(dir, IdentityFileName)); !os.IsNotExist(err) {
		t.Fatal("refusal created identity")
	}
}
