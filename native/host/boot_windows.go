// SPDX-License-Identifier: MIT

package host

import (
	"strconv"

	"golang.org/x/sys/windows/registry"
)

// systemBootID reads the boot counter Windows increments on every start.
func systemBootID() (string, error) {
	key, err := registry.OpenKey(registry.LOCAL_MACHINE,
		`SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters`, registry.QUERY_VALUE)
	if err != nil {
		return "", err
	}
	defer key.Close()
	count, _, err := key.GetIntegerValue("BootId")
	if err != nil {
		return "", err
	}
	return strconv.FormatUint(count, 10), nil
}
