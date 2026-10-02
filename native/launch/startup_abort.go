//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package launch

import (
	"context"
	"errors"
	"os"
)

func abortStartedOwner(state, launchID string) error {
	s, err := readStartup(state)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if s.Launch != launchID || s.Stopped || s.Ready {
		return nil
	}
	held, err := holdOwnerProcessExit(s.PID)
	if err != nil {
		return err
	}
	defer held.close()
	process, err := os.FindProcess(s.PID)
	if err != nil {
		return err
	}
	if err := process.Kill(); err != nil && !errors.Is(err, os.ErrProcessDone) {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), stopTimeout)
	defer cancel()
	return held.wait(ctx)
}
