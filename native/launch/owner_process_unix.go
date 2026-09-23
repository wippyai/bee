//go:build meshclient && physicalclient && !windows

// SPDX-License-Identifier: MIT

package launch

import (
	"os/exec"
	"syscall"
)

// detachOwner starts the owner in its own session so the client's terminal
// signals and exit never reach it.
func detachOwner(command *exec.Cmd) error {
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	return nil
}
