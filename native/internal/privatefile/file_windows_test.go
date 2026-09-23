// SPDX-License-Identifier: MIT

//go:build windows

package privatefile

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/windows"
)

func TestWindowsSecureCreationAndReopen(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "store")
	f, err := New(dir, "doc.txt", ".doc.lock")
	if err != nil {
		t.Fatal(err)
	}

	err = f.ReadModifyWrite(context.Background(), 1024, func(existing []byte) ([]byte, error) {
		return []byte("initial-windows-payload"), nil
	})
	if err != nil {
		t.Fatal(err)
	}

	docPath := filepath.Join(dir, "doc.txt")
	lockPath := filepath.Join(dir, ".doc.lock")
	for _, path := range []string{dir, lockPath, docPath} {
		if err := checkWindowsProtectedOwnerACL(path); err != nil {
			t.Fatalf("path %q failed ACL check: %v", path, err)
		}
	}

	// Reopen and verify content
	f2, err := New(dir, "doc.txt", ".doc.lock")
	if err != nil {
		t.Fatal(err)
	}

	data, err := f2.Read(context.Background(), 1024)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "initial-windows-payload" {
		t.Fatalf("content mismatch on reopen: got %q", string(data))
	}
}

func TestWindowsExistingDirectoryACLIsNotRepaired(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "existing_insecure")
	if err := ensurePrivateDir(dir); err != nil {
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

	f, err := New(dir, "doc.txt", ".doc.lock")
	if err != nil {
		t.Fatal(err)
	}

	if err := f.ReadModifyWrite(context.Background(), 1024, func(existing []byte) ([]byte, error) { return nil, nil }); err == nil {
		t.Fatal("insecure ACL accepted")
	}

	if readACL() != before {
		t.Fatal("validation changed existing ACL")
	}

	docPath := filepath.Join(dir, "doc.txt")
	if _, err := os.Stat(docPath); !os.IsNotExist(err) {
		t.Fatal("refusal created document")
	}
}

func TestWindowsBasenameValidation(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "store")
	testCases := []struct {
		name string
		doc  string
		lock string
	}{
		{"ADSColonInDoc", "file.txt:stream", ".lock"},
		{"ADSColonInLock", "file.txt", ".lock:stream"},
		{"ReservedCON", "CON", ".lock"},
		{"ReservedCONTxt", "con.txt", ".lock"},
		{"ReservedNUL", "file.txt", "NUL"},
		{"ReservedAUX", "aux.json", ".lock"},
		{"ReservedPRN", "prn", ".lock"},
		{"ReservedCOM1", "com1.log", ".lock"},
		{"ReservedLPT3", "lpt3", ".lock"},
		{"InvalidAngleBracket", "doc<bad>", ".lock"},
		{"InvalidPipe", "doc|bad", ".lock"},
		{"InvalidQuestion", "doc?bad", ".lock"},
		{"InvalidStar", "doc*bad", ".lock"},
		{"TrailingDot", "doc.", ".lock"},
		{"TrailingSpace", "doc ", ".lock"},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := New(dir, tc.doc, tc.lock)
			if err == nil {
				t.Fatalf("expected error for %s, got nil", tc.name)
			}
			if !errors.Is(err, ErrInvalidName) {
				t.Fatalf("expected ErrInvalidName for %s, got: %v", tc.name, err)
			}
		})
	}
}

func TestDocumentCannotAliasLockByCase(t *testing.T) {
	if _, err := New(t.TempDir(), "state.json", "STATE.JSON"); err == nil {
		t.Fatal("document and lock alias accepted")
	}
}
