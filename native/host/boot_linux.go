// SPDX-License-Identifier: MIT

package host

import (
	"os"
	"strings"
)

// systemBootID reads the kernel's random identity of the current boot.
func systemBootID() (string, error) {
	data, err := os.ReadFile("/proc/sys/kernel/random/boot_id")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(data)), nil
}
