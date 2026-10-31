// SPDX-License-Identifier: MIT

package host

// processGroupPresent has no process group to observe on Windows.
func processGroupPresent(int) (bool, error) {
	return false, errGroupUnsupported
}
