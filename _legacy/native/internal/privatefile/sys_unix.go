// SPDX-License-Identifier: MIT

//go:build !windows

package privatefile

import (
	"errors"
	"fmt"
	"os"

	"golang.org/x/sys/unix"
)

func tryLockFile(file *os.File) (func() error, error) {
	err := unix.Flock(int(file.Fd()), unix.LOCK_EX|unix.LOCK_NB)
	if errors.Is(err, unix.EWOULDBLOCK) || errors.Is(err, unix.EAGAIN) {
		return nil, errLockBusy
	}
	if err != nil {
		return nil, err
	}
	return func() error {
		return unix.Flock(int(file.Fd()), unix.LOCK_UN)
	}, nil
}

func openLockFile(path string) (*os.File, error) {
	fd, err := unix.Open(path, unix.O_RDWR|unix.O_CREAT|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0600)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fd), path), nil
}

func openExistingFile(path string) (*os.File, error) {
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fd), path), nil
}

func ensurePrivateDir(path string) error {
	return os.MkdirAll(path, 0700)
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
	perm := fi.Mode().Perm()
	if perm&0077 != 0 {
		return fmt.Errorf("file has insecure permissions %04o (must be owner-only, e.g. 0600)", perm)
	}
	return nil
}

func checkFilePathPermissions(path string) error {
	fi, err := os.Lstat(path)
	if err != nil {
		return err
	}
	return checkFilePermissions(fi)
}

func checkDirPermissions(dir string) error {
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
	if st.Mode().Perm()&0077 != 0 {
		return fmt.Errorf("directory %q has insecure permissions %04o (must be owner-only, e.g. 0700)", dir, st.Mode().Perm())
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
	if fi.IsDir() {
		return os.Chmod(path, 0700)
	}
	return os.Chmod(path, 0600)
}

func syncDirChecked(dir string) error {
	d, err := os.Open(dir)
	if err != nil {
		return fmt.Errorf("open directory for sync: %w", err)
	}
	defer d.Close()
	if err := d.Sync(); err != nil {
		return fmt.Errorf("fsync directory %q: %w", dir, err)
	}
	return nil
}

func validateBasenamePlatform(name string) error {
	return nil
}

func sameFilename(a, b string) bool { return a == b }
