//go:build !windows

// SPDX-License-Identifier: MIT

package launch

import "syscall"

// signalOwner sends the owner the termination signal its runtime answers with
// a graceful shutdown.
func signalOwner(pid int) error { return syscall.Kill(pid, syscall.SIGTERM) }
