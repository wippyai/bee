//go:build windows

// SPDX-License-Identifier: MIT

package launch

import "errors"

// signalOwner has no graceful form on Windows: a detached owner shares no
// console with this process, so no console control event reaches it, and
// terminating the process would skip the runtime's shutdown.
func signalOwner(int) error {
	return errors.New("bee stop cannot signal a detached owner on Windows")
}
