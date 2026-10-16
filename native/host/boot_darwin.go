// SPDX-License-Identifier: MIT

package host

import "golang.org/x/sys/unix"

// systemBootID reads the kernel's identity of the current boot session.
func systemBootID() (string, error) {
	return unix.Sysctl("kern.bootsessionuuid")
}
