// SPDX-License-Identifier: MIT

package identity

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// TestDirPermissionsSymlinkRejection verifies that OpenOrCreate fails closed on directory symlinks.
func TestDirPermissionsSymlinkRejection(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlink test specific to POSIX / non-elevated Unix environments")
	}

	parent := t.TempDir()
	realDir := filepath.Join(parent, "real_dir")
	if err := os.Mkdir(realDir, 0700); err != nil {
		t.Fatal(err)
	}

	symlinkDir := filepath.Join(parent, "symlink_dir")
	if err := os.Symlink(realDir, symlinkDir); err != nil {
		t.Fatal(err)
	}

	// OpenOrCreate must fail closed on symlink directory.
	_, err := OpenOrCreate(context.Background(), symlinkDir)
	if err == nil {
		t.Fatal("expected OpenOrCreate to reject symlink directory, got nil")
	}
	if !strings.Contains(err.Error(), "symlink") {
		t.Fatalf("expected symlink error from OpenOrCreate, got: %v", err)
	}
}

// TestLockFileSymlinkRejectionAndNoForeignMutation verifies that OpenOrCreate never follows
// symlinks for the lock file and never mutates target files or unlinks inodes.
func TestLockFileSymlinkRejectionAndNoForeignMutation(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlink test specific to POSIX / non-elevated Unix environments")
	}

	parent := t.TempDir()
	dir := filepath.Join(parent, "ident_dir")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}

	// Create a canary file that must not be mutated.
	canaryPath := filepath.Join(parent, "foreign_canary.txt")
	canaryOriginalContent := []byte("do-not-mutate-foreign-data")
	if err := os.WriteFile(canaryPath, canaryOriginalContent, 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(canaryPath, 0644); err != nil {
		t.Fatal(err)
	}

	// Create symlink: dir/.identity.lock -> canaryPath
	lockSymlink := filepath.Join(dir, LockFileName)
	if err := os.Symlink(canaryPath, lockSymlink); err != nil {
		t.Fatal(err)
	}

	// Attempting OpenOrCreate must fail.
	_, err := OpenOrCreate(context.Background(), dir)
	if err == nil {
		t.Fatal("expected OpenOrCreate to fail on symlink lock file, got nil")
	}

	// Verify the canary file was NOT mutated in content.
	content, err := os.ReadFile(canaryPath)
	if err != nil {
		t.Fatalf("failed to read canary: %v", err)
	}
	if string(content) != string(canaryOriginalContent) {
		t.Fatalf("canary file content was mutated: got %q, want %q", string(content), string(canaryOriginalContent))
	}

	// Verify canary permissions were NOT mutated (e.g. chmod to 0600).
	fi, err := os.Stat(canaryPath)
	if err != nil {
		t.Fatalf("stat canary: %v", err)
	}
	if fi.Mode().Perm() != 0644 {
		t.Fatalf("canary file mode was mutated: got %04o, want 0644", fi.Mode().Perm())
	}

	// Verify the lock file symlink was NEVER unlinked.
	lfi, err := os.Lstat(lockSymlink)
	if err != nil {
		t.Fatalf("lock symlink was removed: %v", err)
	}
	if lfi.Mode()&os.ModeSymlink == 0 {
		t.Fatal("lock symlink was replaced by a regular file")
	}
}

// TestLockFileInsecurePermissionsRejection verifies that an existing lock file with group
// or world permissions is rejected and never unlinked.
func TestLockFileInsecurePermissionsRejection(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("POSIX permission test")
	}

	dir := filepath.Join(t.TempDir(), "ident")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	lockPath := filepath.Join(dir, LockFileName)

	// Pre-create lock file with insecure permissions (0666).
	if err := os.WriteFile(lockPath, []byte("pre-existing"), 0666); err != nil {
		t.Fatal(err)
	}
	// Explicitly chmod to ensure umask did not mask it
	if err := os.Chmod(lockPath, 0666); err != nil {
		t.Fatal(err)
	}

	// OpenOrCreate must fail closed.
	_, err := OpenOrCreate(context.Background(), dir)
	if err == nil {
		t.Fatal("expected OpenOrCreate to reject insecure lock file, got nil")
	}
	if !strings.Contains(err.Error(), "insecure") {
		t.Fatalf("expected 'insecure' error, got: %v", err)
	}

	// The lock file inode must NOT be unlinked.
	fi, err := os.Lstat(lockPath)
	if err != nil {
		t.Fatalf("lock file was unlinked: %v", err)
	}
	if fi.Mode().Perm() != 0666 {
		t.Fatalf("lock file permissions were mutated: got %04o, want 0666", fi.Mode().Perm())
	}
}
