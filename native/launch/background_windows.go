//go:build meshclient && physicalclient && windows

// SPDX-License-Identifier: MIT
package launch

import (
	"golang.org/x/sys/windows"
	"os/exec"
	"syscall"
)

func detachOwner(command *exec.Cmd) error {
	command.SysProcAttr = &syscall.SysProcAttr{CreationFlags: windows.CREATE_NEW_PROCESS_GROUP | windows.DETACHED_PROCESS}
	return nil
}
