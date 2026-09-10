//go:build ownerintegration

// SPDX-License-Identifier: MIT
package owner

import (
	"context"
	"testing"
	"time"
)

func TestStopDoesNotHoldManagerLockWhileClosingAttachment(t *testing.T) {
	manager := New(nil)
	_, cancel := context.WithCancel(context.Background())
	attachment := &Attachment{manager: manager, serveCancel: cancel}
	manager.active[attachment] = "test-owner"
	manager.owners["test-owner"] = 1
	done := make(chan error, 1)
	go func() { done <- manager.Stop(context.Background()) }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(100 * time.Millisecond):
		t.Fatal("Stop deadlocks closing an attachment under the manager mutex")
	}
}
