// SPDX-License-Identifier: MIT
package hive

import (
	"strings"
	"testing"
)

func TestLaunchArgumentsPreserveLiteralValuesAndBoundResources(t *testing.T) {
	good := DesktopCommand{Name: "terminal", Arguments: []string{"a b", "$(exit 4)", "", "--flag"}}
	if !good.Valid() {
		t.Fatal("literal command rejected")
	}
	for _, name := range []string{"", "Terminal", "terminal;id", ":app", strings.Repeat("x", 41)} {
		if (DesktopCommand{Name: name}).Valid() {
			t.Fatalf("invalid command accepted: %q", name)
		}
	}
	for _, args := range [][]string{{"line\nfeed"}, {"\x00"}, {"\x7f"}, {strings.Repeat("x", 1025)}, make([]string, 17), {strings.Repeat("x", 1024), strings.Repeat("x", 1024), strings.Repeat("x", 1024), strings.Repeat("x", 1024), strings.Repeat("x", 1024), strings.Repeat("x", 1024), strings.Repeat("x", 1024), strings.Repeat("x", 1024), "x"}} {
		if (DesktopCommand{Name: "terminal", Arguments: args}).Valid() {
			t.Fatal("unbounded or control-character arguments accepted")
		}
	}
}
