//go:build physicalclient && !windows

// SPDX-License-Identifier: MIT
package physical

import (
	"context"
	"errors"
	"io"
	"testing"
	"time"

	tty "github.com/wippyai/runtime/api/tty"
)

type cancelUnwindingViewport struct {
	*stalledViewport
	canceled chan struct{}
	release  chan struct{}
}

func (v *cancelUnwindingViewport) ResizeContext(ctx context.Context, _, _ int) error {
	v.once.Do(func() { close(v.submitted) })
	<-ctx.Done()
	close(v.canceled)
	<-v.release
	// A native call can observe either local cancellation or mount retirement.
	// If its owner closes the mount first, the original cancellation is obscured.
	select {
	case <-v.closed:
		return tty.ErrMountExpired
	default:
		return ctx.Err()
	}
}

func TestDetachDrainsCanceledOperationBeforeClosingMount(t *testing.T) {
	_, slave, before := terminalPair(t)
	view := &cancelUnwindingViewport{stalledViewport: newViewport(control), canceled: make(chan struct{}), release: make(chan struct{})}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- Run(ctx, view, control, slave, io.Discard) }()
	select {
	case <-view.submitted:
	case <-time.After(3 * time.Second):
		t.Fatal("resize was not submitted")
	}
	cancel()
	select {
	case <-view.canceled:
	case <-time.After(3 * time.Second):
		t.Fatal("operation did not receive cancellation")
	}
	closedEarly := false
	select {
	case <-view.closed:
		closedEarly = true
	case <-time.After(50 * time.Millisecond):
	}
	close(view.release)
	select {
	case err := <-done:
		if closedEarly || errors.Is(err, tty.ErrMountExpired) {
			t.Fatalf("local detach retired the mount before cancellation drained: %v", err)
		}
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("detach did not finish")
	}
	restored(t, slave, before)
}
