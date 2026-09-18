//go:build windows && amd64

// SPDX-License-Identifier: MIT
package driver

import "testing"

func TestNewerInteractiveLogon(t *testing.T) {
	previous := "windows:1:old:100"
	for _, current := range []string{previous, "windows:1:runas:100", "windows:1:old:200", "windows:1:new:ff", "windows:1:new:invalid", "windows:1:new"} {
		if newerInteractiveLogon(previous, current) {
			t.Fatalf("accepted non-replacement %q", current)
		}
	}
	if !newerInteractiveLogon(previous, "windows:1:new:200") || !newerInteractiveLogon(previous, "windows:2:new:200") {
		t.Fatal("rejected later same-slot logon")
	}
}
