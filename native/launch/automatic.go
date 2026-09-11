//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package launch

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/wippyai/bee/native/client/hive"
	"github.com/wippyai/bee/native/hive/rendezvous"
	"github.com/wippyai/bee/native/internal/privatefile"
	application "github.com/wippyai/runtime/api/application"
	"github.com/wippyai/runtime/application/statelock"
)

// Run starts a detached owner contender, then attaches once. The child's normal
// runtime lock selects the owner. A losing contender authenticates the existing
// owner without mounting a desktop before it exits successfully. Discovery hints
// select when to attempt admission; they never grant it. No mutation is replayed.
func (c Client) Run(ctx context.Context, request application.LaunchRequest) error {
	if err := c.validate(ctx, request); err != nil {
		return err
	}
	if !filepath.IsAbs(request.Directory) {
		return errors.New("client launch needs the project directory")
	}
	if err := privatefile.EnsurePrivateDir(request.StateDir); err != nil {
		return err
	}
	busy, err := ownerLockBusy(request.StateDir)
	if err != nil {
		return err
	}
	if busy {
		if _, err := fmt.Fprintln(c.Stdout, "Connecting to Hive…"); err != nil {
			return err
		}
		// The runtime lock is only a routing hint. Attach independently
		// authenticates the owner; refusal never starts a competing owner.
		return c.Attach(ctx, request)
	}
	if c.AttachOnly {
		return errors.New("No running Bee for this project; run bee to start its node")
	}
	if c.Mode == hive.Observe {
		return errors.New("No running Bee to observe; start bee first")
	}
	if c.Selection.Workspace != "" {
		return errors.New("No running Bee for the selected desktop; start bee first")
	}
	if _, err := fmt.Fprintln(c.Stdout, "Starting Bee…"); err != nil {
		return err
	}
	store, err := rendezvous.New(filepath.Join(request.StateDir, rendezvous.DirectoryName))
	if err != nil {
		return err
	}
	previous, err := store.Read(ctx)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := privatefile.EnsurePrivateDir(request.StateDir); err != nil {
		return err
	}
	log, err := os.CreateTemp(request.StateDir, "owner-*.log")
	if err != nil {
		return err
	}
	defer log.Close()
	if err := privatefile.SetOwnerOnlyPermissions(log.Name()); err != nil {
		return err
	}
	child, err := StartOwner(ctx, request, log)
	if err != nil {
		return err
	}
	startup, cancel := context.WithTimeout(ctx, 30*time.Second)
	err = waitOwnerPublication(startup, store.Read, previous, child.Done(), child.Wait)
	cancel()
	if err != nil {
		return fmt.Errorf("Bee owner startup (log %s): %w", log.Name(), err)
	}
	// Detach/cancellation ends only this client. Never abort the retained owner.
	if err := c.Attach(ctx, request); err != nil {
		return fmt.Errorf("Bee client attachment (owner log %s): %w", log.Name(), err)
	}
	return nil
}

// Release a free runtime lock before spawning. The child must acquire it again;
// another launcher winning that race is handled by the existing contender path.
func ownerLockBusy(state string) (bool, error) {
	unlock, err := statelock.Acquire(state)
	if errors.Is(err, statelock.ErrBusy) {
		return true, nil
	}
	if err != nil {
		return false, err
	}
	return false, unlock()
}

func waitOwnerPublication(ctx context.Context, read func(context.Context) (rendezvous.Descriptor, error), previous rendezvous.Descriptor, done <-chan struct{}, wait func(context.Context) error) error {
	tick := time.NewTicker(25 * time.Millisecond)
	defer tick.Stop()
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		select {
		case <-done:
			// Success means the losing start contender completed a read-only native
			// owner probe. The subsequent client attachment authenticates independently.
			return wait(ctx)
		default:
		}
		current, err := read(ctx)
		if err == nil && current != previous {
			return nil
		}
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-done:
			return wait(ctx)
		case <-tick.C:
		}
	}
}
