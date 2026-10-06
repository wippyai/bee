//go:build unix

// SPDX-License-Identifier: MIT

package hive

import (
	"os"
	"syscall"
)

// replaceProcess runs path with args in this process, closing its descriptors,
// the folder lock included.
func replaceProcess(path string, args []string) error {
	return syscall.Exec(path, args, os.Environ())
}

// interruptSelf asks this process to stop the way a person's Ctrl+C does.
func interruptSelf() {
	_ = syscall.Kill(os.Getpid(), syscall.SIGTERM)
}
