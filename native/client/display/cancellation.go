// SPDX-License-Identifier: MIT
package display

import (
	"context"
	"sync"
)

// watchCancellation stops or joins the callback before its caller releases ownership.
func watchCancellation(ctx context.Context, callback func()) func() {
	done := make(chan struct{})
	stop := context.AfterFunc(ctx, func() { defer close(done); callback() })
	var once sync.Once
	return func() {
		once.Do(func() {
			if !stop() {
				<-done
			}
		})
	}
}
