//go:build meshclient && physicalclient && windows

// SPDX-License-Identifier: MIT

package launch

import "os/exec"

// detachOwner relies on the Windows default: the child gets no inherited console
// handles from Start.
func detachOwner(*exec.Cmd) error { return nil }
