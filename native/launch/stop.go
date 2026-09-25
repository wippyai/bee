// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"errors"
	"time"

	app "github.com/wippyai/runtime/cmd/app"
)

// stopTimeout bounds the wait for an owner to release the state after it
// accepted a stop.
const stopTimeout = 2 * time.Minute

// waitReleased waits until no owner holds state.
func waitReleased(ctx context.Context, state string) error {
	deadline := time.Now().Add(stopTimeout)
	for {
		owned, err := app.Owned(state)
		if err != nil || !owned {
			return err
		}
		if time.Now().After(deadline) {
			return errors.New("Bee did not stop within " + stopTimeout.String())
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(waitPollInterval):
		}
	}
}
