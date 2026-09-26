//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/wippyai/bee/native/hive/rendezvous"
	app "github.com/wippyai/runtime/cmd/app"
)

// defaultCutoverSeams wires the cutover to the authenticated client channel
// for the drain, the state lock for the handoff wait and detached owner
// starts with rendezvous readiness for the new binary.
func defaultCutoverSeams() cutoverSeams {
	return cutoverSeams{
		stopOld: func(ctx context.Context, state, dir string) error {
			return runClientRoute(ctx,
				app.Launch{Op: app.OpRun, Command: desktopCommand, State: state, Dir: dir, Explicit: true},
				clientIntent{stop: true})
		},
		stopOldCompatible: stopCutoverCompatible,
		waitReleased:       waitReleased,
		start:              startCutoverOwner,
		currentExecutable:  os.Executable,
	}
}

// stopCutoverCompatible stops the state through an older retained binary
// when this binary cannot speak to the running owner.
func stopCutoverCompatible(ctx context.Context, state, previous string) error {
	timeout, cancel := context.WithTimeout(ctx, stopTimeout)
	defer cancel()
	command := exec.CommandContext(timeout, previous, "--state", state, "stop")
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("the retained previous Bee did not stop the owner: %w: %s", err, string(output))
	}
	return nil
}

// startCutoverOwner starts executable as a detached owner of state and waits
// for its fresh readiness publication. A publication from another contender
// or an older protocol fails the start.
func startCutoverOwner(ctx context.Context, state, dir, executable string) error {
	if !filepath.IsAbs(state) || !filepath.IsAbs(dir) {
		return errors.New("cutover owner start requires absolute state and project directories")
	}
	directory := filepath.Join(state, rendezvous.DirectoryName)
	previous, err := readDescriptor(ctx, directory)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	launchID, err := newLaunchIdentity()
	if err != nil {
		return err
	}
	log, err := openOwnerLog(state)
	if err != nil {
		return err
	}
	command := execOwnerCommand(executable, app.Launch{State: state, Dir: dir}, log)
	command.Env = append(os.Environ(), ownerLaunchVariable+"="+launchID)
	done, wait, err := startDetachedCommand(ctx, command)
	if err != nil {
		_ = log.Close()
		return err
	}
	releaseLog := func() error { return errors.Join(wait(), log.Close()) }
	startup, cancel := context.WithTimeout(ctx, waitOwnerTimeout)
	defer cancel()
	held := func() (bool, error) { return app.Owned(state) }
	published, err := waitDescriptorOrExit(startup, readDescriptor, directory, previous, done, releaseLog, held)
	if err != nil {
		return fmt.Errorf("cutover owner did not publish its readiness: %w", err)
	}
	if published.Launch != launchID {
		return errors.New("another Bee owner holds the state after the cutover start")
	}
	if published.ClientRevision != rendezvous.ClientRevision {
		return incompatibleOwner(state, published.ClientRevision)
	}
	return nil
}
