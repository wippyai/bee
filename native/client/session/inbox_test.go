//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package session

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestInboxFailureRetiresPresentationWithCause(t *testing.T) {
	done := make(chan struct{})
	failure := errors.New("inbox overflow")
	ctx, stop := withInboxLifetime(context.Background(), done, func() error { return failure })
	defer stop()
	close(done)
	select {
	case <-ctx.Done():
		if !errors.Is(context.Cause(ctx), failure) {
			t.Fatal(context.Cause(ctx))
		}
	case <-time.After(time.Second):
		t.Fatal("presentation survived inbox failure")
	}
}

func TestPresentationExitJoinsInboxWatcher(t *testing.T) {
	ctx, stop := withInboxLifetime(context.Background(), make(chan struct{}), func() error {
		t.Error("live inbox treated as failed")
		return nil
	})
	stop()
	if !errors.Is(context.Cause(ctx), context.Canceled) {
		t.Fatal(context.Cause(ctx))
	}
}
