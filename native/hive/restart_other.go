//go:build !unix

// SPDX-License-Identifier: MIT

package hive

import "os"

// replaceProcess is unavailable where a process cannot replace itself.
func replaceProcess(string, []string) error { return errRelaunchUnsupported }

// interruptSelf asks this process to stop.
func interruptSelf() {
	if process, err := os.FindProcess(os.Getpid()); err == nil {
		_ = process.Signal(os.Interrupt)
	}
}
