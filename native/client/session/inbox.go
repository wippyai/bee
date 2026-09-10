//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package session

import "context"

// An inbox failure also stops presentation/input. A transport that remains
// reachable cannot keep a retired client operating its old viewport.
func withInboxLifetime(parent context.Context, done <-chan struct{}, failure func() error) (context.Context, func()) {
	ctx, cancel := context.WithCancelCause(parent)
	joined := make(chan struct{})
	go func() {
		defer close(joined)
		select {
		case <-done:
			cancel(failure())
		case <-ctx.Done():
		}
	}()
	return ctx, func() { cancel(context.Canceled); <-joined }
}
