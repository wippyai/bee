//go:build !linux

// SPDX-License-Identifier: MIT
package launch

import "github.com/syncthing/notify"

func cacheProgressEvents() []notify.Event {
	return []notify.Event{notify.Create, notify.Write, notify.Rename, notify.Remove}
}
func cacheVerificationRead(event notify.Event) bool { return false }
