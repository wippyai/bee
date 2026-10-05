// SPDX-License-Identifier: MIT

package launch

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"

	"github.com/wippyai/bee/native/hive/rendezvous"
)

// ownerLaunchVariable carries the launch identity a client hands the owner it
// starts; the owner publishes it in its rendezvous descriptor.
const ownerLaunchVariable = "BEE_OWNER_LAUNCH"

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
