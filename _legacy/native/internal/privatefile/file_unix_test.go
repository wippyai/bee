// SPDX-License-Identifier: MIT

//go:build !windows

package privatefile

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDirPermissionsSymlinkRejection(t *testing.T) {
	parent := t.TempDir()
	realDir := filepath.Join(parent, "real_dir")
	if err := os.Mkdir(realDir, 0700); err != nil {
		t.Fatal(err)
	}

	symlinkDir := filepath.Join(parent, "symlink_dir")
	if err := os.Symlink(realDir, symlinkDir); err != nil {
		t.Fatal(err)
	}

	f, err := New(symlinkDir, "doc.txt", ".doc.lock")
	if err != nil {
		t.Fatal(err)
	}

	// checkDirPermissions must reject symlink directory via Lstat.
	if err := checkDirPermissions(symlinkDir); err == nil {
		t.Fatal("expected checkDirPermissions to reject symlink directory, got nil")
	} else if !strings.Contains(err.Error(), "symlink") {
		t.Fatalf("expected symlink error, got: %v", err)
	}

	// ReadModifyWrite must also fail closed on symlink directory.
	err = f.ReadModifyWrite(context.Background(), 1024, func(existing []byte) ([]byte, error) { return nil, nil })
	if err == nil {
		t.Fatal("expected ReadModifyWrite to reject symlink directory, got nil")
	}
	if !strings.Contains(err.Error(), "symlink") {
		t.Fatalf("expected symlink error from ReadModifyWrite, got: %v", err)
	}
}

func TestDirPermissionsNotADirectory(t *testing.T) {
	parent := t.TempDir()
	filePath := filepath.Join(parent, "some_file")
	if err := os.WriteFile(filePath, []byte("data"), 0600); err != nil {
		t.Fatal(err)
	}

	err := checkDirPermissions(filePath)
	if err == nil {
		t.Fatal("expected checkDirPermissions to reject file path, got nil")
	}
	if !strings.Contains(err.Error(), "not a directory") {
		t.Fatalf("expected 'not a directory' error, got: %v", err)
	}
}

func TestLockFileSymlinkRejectionAndNoForeignMutation(t *testing.T) {
	parent := t.TempDir()
	dir := filepath.Join(parent, "store")
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

	// Symlink: dir/.test.lock -> canaryPath
	lockSymlink := filepath.Join(dir, ".test.lock")
	if err := os.Symlink(canaryPath, lockSymlink); err != nil {
		t.Fatal(err)
	}

	f, err := New(dir, "doc.txt", ".test.lock")
	if err != nil {
		t.Fatal(err)
	}

	// Attempting acquireLock directly must fail.
	_, err = acquireLock(context.Background(), lockSymlink)
	if err == nil {
		t.Fatal("expected acquireLock to fail on symlink lock file, got nil")
	}

	// Attempting ReadModifyWrite must also fail.
	err = f.ReadModifyWrite(context.Background(), 1024, func(existing []byte) ([]byte, error) { return nil, nil })
	if err == nil {
		t.Fatal("expected ReadModifyWrite to fail on symlink lock file, got nil")
	}

	// Verify the canary file was NOT mutated in content.
	content, err := os.ReadFile(canaryPath)
	if err != nil {
		t.Fatalf("failed to read canary: %v", err)
	}
	if string(content) != string(canaryOriginalContent) {
		t.Fatalf("canary file content was mutated: got %q, want %q", string(content), string(canaryOriginalContent))
	}

	// Verify canary permissions were NOT mutated.
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

func TestLockFileInsecurePermissionsRejection(t *testing.T) {
	dir := privateTestDir(t)
	lockPath := filepath.Join(dir, ".insecure.lock")

	if err := os.WriteFile(lockPath, []byte("pre-existing"), 0666); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(lockPath, 0666); err != nil {
		t.Fatal(err)
	}

	f, err := New(dir, "doc.txt", ".insecure.lock")
	if err != nil {
		t.Fatal(err)
	}

	// acquireLock must fail closed.
	_, err = acquireLock(context.Background(), lockPath)
	if err == nil {
		t.Fatal("expected acquireLock to reject insecure lock file, got nil")
	}
	if !strings.Contains(err.Error(), "insecure") {
		t.Fatalf("expected 'insecure' error, got: %v", err)
	}

	// ReadModifyWrite must fail closed.
	err = f.ReadModifyWrite(context.Background(), 1024, func(existing []byte) ([]byte, error) { return nil, nil })
	if err == nil {
		t.Fatal("expected ReadModifyWrite to reject insecure lock file, got nil")
	}

	// The lock file inode must NOT be unlinked or repaired.
	fi, err := os.Lstat(lockPath)
	if err != nil {
		t.Fatalf("lock file was unlinked: %v", err)
	}
	if fi.Mode().Perm() != 0666 {
		t.Fatalf("lock file permissions were mutated: got %04o, want 0666", fi.Mode().Perm())
	}
}

func TestLockFileNonRegularRejection(t *testing.T) {
	dir := privateTestDir(t)
	lockDirPath := filepath.Join(dir, ".dir.lock")
	if err := os.Mkdir(lockDirPath, 0700); err != nil {
		t.Fatal(err)
	}

	f, err := New(dir, "doc.txt", ".dir.lock")
	if err != nil {
		t.Fatal(err)
	}

	err = f.ReadModifyWrite(context.Background(), 1024, func(existing []byte) ([]byte, error) { return nil, nil })
	if err == nil {
		t.Fatal("expected ReadModifyWrite to fail when lock path is a directory, got nil")
	}
	if !strings.Contains(err.Error(), "not a regular file") {
		t.Fatalf("expected 'not a regular file' error, got: %v", err)
	}
}

func TestDocumentSymlinkRejection(t *testing.T) {
	parent := t.TempDir()
	dir := filepath.Join(parent, "store")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}

	canaryPath := filepath.Join(parent, "canary.txt")
	if err := os.WriteFile(canaryPath, []byte("target"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(canaryPath, 0644); err != nil {
		t.Fatal(err)
	}

	docSymlink := filepath.Join(dir, "doc.txt")
	if err := os.Symlink(canaryPath, docSymlink); err != nil {
		t.Fatal(err)
	}

	f, err := New(dir, "doc.txt", ".doc.lock")
	if err != nil {
		t.Fatal(err)
	}

	// Read must refuse symlink document
	_, err = f.Read(context.Background(), 1024)
	if err == nil {
		t.Fatal("expected Read to reject symlink document, got nil")
	}
	if !strings.Contains(err.Error(), "symlink") && !strings.Contains(err.Error(), "not a regular file") {
		t.Fatalf("expected symlink or regular file error, got: %v", err)
	}

	// ReadModifyWrite must also refuse
	err = f.ReadModifyWrite(context.Background(), 1024, func(existing []byte) ([]byte, error) {
		return []byte("new"), nil
	})
	if err == nil {
		t.Fatal("expected ReadModifyWrite to reject symlink document, got nil")
	}

	// Target canary file must remain untouched
	canaryContent, err := os.ReadFile(canaryPath)
	if err != nil || string(canaryContent) != "target" {
		t.Fatalf("canary content altered: %s", string(canaryContent))
	}
}

func TestInsecureDocumentNotRepaired(t *testing.T) {
	dir := privateTestDir(t)
	f, err := New(dir, "doc.txt", ".doc.lock")
	if err != nil {
		t.Fatal(err)
	}

	err = f.ReadModifyWrite(context.Background(), 1024, func(existing []byte) ([]byte, error) {
		return []byte("secret"), nil
	})
	if err != nil {
		t.Fatal(err)
	}

	docPath := filepath.Join(dir, "doc.txt")
	// Insecure mode
	if err := os.Chmod(docPath, 0644); err != nil {
		t.Fatal(err)
	}

	// Read must reject
	_, err = f.Read(context.Background(), 1024)
	if err == nil {
		t.Fatal("expected Read to reject 0644 file, got nil")
	}
	if !strings.Contains(err.Error(), "insecure") {
		t.Fatalf("expected insecure error, got: %v", err)
	}

	// ReadModifyWrite must also reject
	err = f.ReadModifyWrite(context.Background(), 1024, func(existing []byte) ([]byte, error) {
		return []byte("replacement"), nil
	})
	if err == nil {
		t.Fatal("expected ReadModifyWrite to reject 0644 file, got nil")
	}
	if !strings.Contains(err.Error(), "insecure") {
		t.Fatalf("expected insecure error from ReadModifyWrite, got: %v", err)
	}

	// Verify permissions were NOT repaired
	fi, err := os.Stat(docPath)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0644 {
		t.Fatalf("file permissions were repaired to %04o", fi.Mode().Perm())
	}
}

func TestInsecureDirectoryNotRepaired(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "insecure_dir")
	if err := os.Mkdir(dir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0755); err != nil {
		t.Fatal(err)
	}

	f, err := New(dir, "doc.txt", ".doc.lock")
	if err != nil {
		t.Fatal(err)
	}

	err = f.ReadModifyWrite(context.Background(), 1024, func(existing []byte) ([]byte, error) { return nil, nil })
	if err == nil {
		t.Fatal("expected ReadModifyWrite on 0755 dir to fail, got nil")
	}
	if !strings.Contains(err.Error(), "insecure") {
		t.Fatalf("expected insecure error, got: %v", err)
	}

	// Permissions must not be repaired
	st, err := os.Stat(dir)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0755 {
		t.Fatalf("directory permissions were repaired to %04o", st.Mode().Perm())
	}
}

func TestSyncDirChecked(t *testing.T) {
	dir := privateTestDir(t)
	if err := syncDirChecked(dir); err != nil {
		t.Fatalf("syncDirChecked on existing directory failed: %v", err)
	}

	nonexistent := filepath.Join(dir, "does-not-exist")
	if err := syncDirChecked(nonexistent); err == nil {
		t.Fatal("expected syncDirChecked on nonexistent dir to fail, got nil")
	}
}

func TestCheckFilePathPermissions(t *testing.T) {
	dir := privateTestDir(t)
	validFile := filepath.Join(dir, "valid.txt")
	if err := os.WriteFile(validFile, []byte("data"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := checkFilePathPermissions(validFile); err != nil {
		t.Fatalf("expected valid file check to pass, got: %v", err)
	}

	insecureFile := filepath.Join(dir, "insecure.txt")
	if err := os.WriteFile(insecureFile, []byte("data"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(insecureFile, 0644); err != nil {
		t.Fatal(err)
	}
	if err := checkFilePathPermissions(insecureFile); err == nil {
		t.Fatal("expected insecure file check to fail, got nil")
	}

	symFile := filepath.Join(dir, "sym.txt")
	if err := os.Symlink(validFile, symFile); err != nil {
		t.Fatal(err)
	}
	if err := checkFilePathPermissions(symFile); err == nil {
		t.Fatal("expected symlink check to fail, got nil")
	}
}

func TestRootDirectWriteDoesNotReplaceInsecureDocument(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "private")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "state.json")
	if err := os.WriteFile(path, []byte("preserve"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0644); err != nil {
		t.Fatal(err)
	}

	file, err := New(dir, "state.json", ".state.lock")
	if err != nil {
		t.Fatal(err)
	}

	err = file.ReadModifyWrite(context.Background(), 1024, func(existing []byte) ([]byte, error) {
		return []byte("replacement"), nil
	})
	if err == nil {
		t.Error("direct write replaced insecure document without refusal")
	}

	data, readErr := os.ReadFile(path)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if string(data) != "preserve" {
		t.Error("insecure document was changed")
	}

	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0644 {
		t.Errorf("insecure document permissions were modified to %04o", fi.Mode().Perm())
	}
}
