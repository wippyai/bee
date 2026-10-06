//go:build windows

// SPDX-License-Identifier: MIT

package hive

import (
	"os"

	"golang.org/x/sys/windows"
)

// tryLock takes an exclusive lock on file without waiting. The lock lasts
// until the file is closed or the process ends.
func tryLock(file *os.File) bool {
	overlapped := &windows.Overlapped{}
	return windows.LockFileEx(windows.Handle(file.Fd()), windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, overlapped) == nil
}
