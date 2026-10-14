//go:build unix

// SPDX-License-Identifier: MIT

package hive

import (
	"os"
	"syscall"
)

// tryLock takes an exclusive lock on file without waiting. The lock lasts
// until the file is closed or the process ends.
func tryLock(file *os.File) bool {
	return syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) == nil
}
