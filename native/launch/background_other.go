//go:build meshclient && physicalclient && !linux && !darwin && !windows

// SPDX-License-Identifier: MIT
package launch

import (
	"errors"
	"os/exec"
)

func detachOwner(*exec.Cmd) error {
	return errors.New("background Bee owner unsupported on this platform")
}
