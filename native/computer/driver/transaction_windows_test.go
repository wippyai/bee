//go:build windows && amd64

// SPDX-License-Identifier: MIT
package driver

import (
	"encoding/binary"
	"fmt"
	"testing"
)

func TestShortcutValidation(t *testing.T) {
	for _, key := range []string{"", "CTRL", "CTRL+CTRL+A", "CTRL+", "A+CTRL", "CONTROL+A", "CTRL+ALT+SHIFT+META+CTRL+A"} {
		if _, _, err := shortcut(key); err == nil {
			t.Fatalf("accepted %q", key)
		}
	}
	for _, key := range []string{"ENTER", "CTRL+A", "CTRL+SHIFT+END", "ALT+TAB", "META+E"} {
		if _, _, err := shortcut(key); err != nil {
			t.Fatalf("rejected %q: %v", key, err)
		}
	}
}

func TestPartialTransactionNeverReplays(t *testing.T) {
	chord, _, _ := shortcut("CTRL+SHIFT+END")
	cases := map[string][]input{
		"shortcut": chord,
		"drag":     {mouse(0xc001, 20, 20, 0), mouse(2, 0, 0, 0), mouse(0xc001, 40, 40, 0), mouse(4, 0, 0, 0)},
		"unicode":  {keyboard(0, 0xd83d, 4), keyboard(0, 0xd83d, 6), keyboard(0, 0xde00, 4), keyboard(0, 0xde00, 6)},
	}
	for name, batch := range cases {
		for prefix := 0; prefix < len(batch); prefix++ {
			t.Run(fmt.Sprintf("%s/%d", name, prefix), func(t *testing.T) {
				calls, retired := 0, false
				if submitTransaction(batch, func(uint16) bool { return false }, func(items []input) int {
					calls++
					if calls == 1 {
						return prefix
					}
					for _, item := range items {
						if binary.LittleEndian.Uint32(item[:4]) == 1 {
							if binary.LittleEndian.Uint32(item[12:16])&2 == 0 {
								t.Fatal("replayed keyboard down")
							}
						} else if binary.LittleEndian.Uint32(item[20:24]) != 4 {
							t.Fatal("replayed movement/down/scroll")
						}
					}
					return len(items)
				}, func() bool { return true }, func() { retired = true }) {
					t.Fatal("partial submission reported success")
				}
				want := 2
				if prefix == 0 {
					want = 1
				}
				if !retired || calls != want {
					t.Fatalf("retired=%v calls=%d", retired, calls)
				}
			})
		}
	}
}

func TestTransactionPreservesExistingHold(t *testing.T) {
	batch, _, _ := shortcut("CTRL+A")
	for _, key := range []uint16{0xa2, 0xa3, 0x41, 1} {
		if submitTransaction(batch, func(k uint16) bool { return k == key }, func([]input) int { t.Fatal("input submitted over existing hold"); return 0 }, func() bool { return true }, func() {}) {
			t.Fatal("accepted existing hold")
		}
	}
}

func TestTransactionCannotCleanAcrossDesktopLoss(t *testing.T) {
	batch, _, _ := shortcut("CTRL+A")
	checks, calls, retired := 0, 0, false
	if submitTransaction(batch, func(uint16) bool { return false }, func([]input) int { calls++; return 1 }, func() bool { checks++; return checks == 1 }, func() { retired = true }) {
		t.Fatal("reported success")
	}
	if calls != 1 || !retired {
		t.Fatalf("cleanup crossed desktop loss: calls=%d retired=%v", calls, retired)
	}
}
