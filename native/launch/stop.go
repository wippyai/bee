// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/wippyai/bee/native/hive/rendezvous"
	app "github.com/wippyai/runtime/cmd/app"
)

// ownerLaunchVariable carries the launch identity a client hands the owner it
// starts; the owner publishes it in its rendezvous descriptor.
const ownerLaunchVariable = "BEE_OWNER_LAUNCH"

// stopTimeout bounds the wait for an owner to release the state after it
// accepted a stop.
const stopTimeout = 2 * time.Minute

func newLaunchIdentity() (string, error) {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(value[:]), nil
}

// launchIdentity reads and clears the launch identity the starting client gave
// this owner, so the owner's own children never inherit it.
func launchIdentity() (string, error) {
	value := os.Getenv(ownerLaunchVariable)
	if err := os.Unsetenv(ownerLaunchVariable); err != nil {
		return "", err
	}
	if value != "" && !rendezvous.LaunchIdentity(value) {
		return "", fmt.Errorf("%s is not a launch identity", ownerLaunchVariable)
	}
	return value, nil
}

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
