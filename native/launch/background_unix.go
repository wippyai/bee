//go:build meshclient && physicalclient && (linux || darwin)

// SPDX-License-Identifier: MIT
package launch

import (
	"os/exec"
	"syscall"
)

func detachOwner(command *exec.Cmd) error {
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	return nil
}
