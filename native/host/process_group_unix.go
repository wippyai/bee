// SPDX-License-Identifier: MIT

//go:build !windows

package host

import (
	"errors"
	"syscall"
)

// processGroupPresent probes the group with signal 0: delivery or a refused
// permission means a member exists, ESRCH means none does.
func processGroupPresent(pgid int) (bool, error) {
	err := syscall.Kill(-pgid, 0)
	switch {
	case err == nil, errors.Is(err, syscall.EPERM):
		return true, nil
	case errors.Is(err, syscall.ESRCH):
		return false, nil
	default:
		return false, err
	}
}
