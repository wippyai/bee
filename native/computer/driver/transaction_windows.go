//go:build windows && amd64

// SPDX-License-Identifier: MIT
package driver

import (
	"encoding/binary"
	"errors"
	"strings"
)

// shortcut expresses a complete bounded chord, never a public held-key handle.
// Physical virtual keys are layout-dependent; text continues to use Unicode.
func shortcut(key string) ([]input, []uint16, error) {
	parts := strings.Split(key, "+")
	if len(key) > 32 || len(parts) > 5 {
		return nil, nil, errors.New("shortcut limit")
	}
	var keys []uint16
	seen := map[uint16]bool{}
	for _, name := range parts[:len(parts)-1] {
		vk := map[string]uint16{"CTRL": 0xa2, "SHIFT": 0xa0, "ALT": 0xa4, "META": 0x5b}[name]
		if vk == 0 || seen[vk] {
			return nil, nil, errors.New("invalid or duplicate modifier")
		}
		seen[vk] = true
		keys = append(keys, vk)
	}
	main := keySym(parts[len(parts)-1])
	if main == 0 {
		return nil, nil, errors.New("unsupported shortcut key")
	}
	keys = append(keys, main)
	var batch []input
	flags := func(vk uint16) uint32 {
		if vk == 0x5b || (vk >= 35 && vk <= 40) || vk == 46 {
			return 1
		}
		return 0
	}
	for _, vk := range keys {
		batch = append(batch, keyboard(vk, 0, flags(vk)))
	}
	for i := len(keys) - 1; i >= 0; i-- {
		batch = append(batch, keyboard(keys[i], 0, flags(keys[i])|2))
	}
	return batch, keys, nil
}

// releasePlan declares every possible release before submission. Cleanup does
// not assume the reported count identifies an exact accepted prefix. It emits
// only key/button ups, in reverse order, never movement, scrolling or text-down.
func releasePlan(batch []input) ([]input, []uint16) {
	var releases []input
	var keys []uint16
	seen := map[input]bool{}
	for i := len(batch) - 1; i >= 0; i-- {
		item := batch[i]
		var release input
		var key uint16
		switch binary.LittleEndian.Uint32(item[:4]) {
		case 1:
			flags := binary.LittleEndian.Uint32(item[12:16])
			if flags&2 != 0 {
				continue
			}
			release = item
			binary.LittleEndian.PutUint32(release[12:16], flags|2)
			key = binary.LittleEndian.Uint16(item[8:10])
			if flags&4 != 0 {
				key = 0xe7
			} // VK_PACKET for Unicode submissions.
		case 0:
			if binary.LittleEndian.Uint32(item[20:24])&2 == 0 {
				continue
			}
			release, key = mouse(4, 0, 0, 0), 1
			copy(release[32:40], item[32:40]) // preserve per-transaction provenance
		default:
			continue
		}
		if !seen[release] {
			seen[release] = true
			releases = append(releases, release)
			keys = append(keys, key)
		}
	}
	return releases, keys
}

// submitTransaction handles returned partial submission only. A guardian is
// still required for process death during SendInput. A global key-state check
// refuses pre-existing input; it cannot arbitrate a concurrent physical press.
func submitTransaction(batch []input, held func(uint16) bool, send func([]input) int, accessible func() bool, retire func()) bool {
	releases, keys := releasePlan(batch)
	// Foreign modifiers can change text/shortcuts, and a held mouse button can
	// turn ordinary movement into a drag. Never release a pre-existing hold.
	for _, key := range append([]uint16{1, 2, 4, 5, 6, 0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0x5b, 0x5c}, keys...) {
		if held(key) {
			return false
		}
	}
	if !accessible() {
		return false
	}
	count := send(batch)
	if count == len(batch) {
		return true
	}
	// An uncertain transaction retires the endpoint even if cleanup submits all
	// releases. No next action can build on an ambiguous application state.
	defer retire()
	if count != 0 && len(releases) != 0 && accessible() {
		send(releases)
	}
	return false
}
