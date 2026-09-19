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
	app "github.com/wippyai/runtime/cmd/app"
)

// Run starts a detached owner contender, then attaches once. The child's normal
// runtime lock selects the owner. A losing contender may exit with the runtime's
// owned-state error; a newly published descriptor then permits one authenticated
// attachment attempt. Discovery hints never grant admission. No mutation is replayed.
func (c Client) Run(ctx context.Context, launch app.Launch) error {
	if err := c.validate(ctx, launch); err != nil {
		return err
	}
	if !filepath.IsAbs(launch.Dir) {
		return errors.New("client launch needs the project directory")
	}
	store, err := rendezvous.New(filepath.Join(launch.State, rendezvous.DirectoryName))
	if err != nil {
		return err
	}
	if c.AttachOnly || c.Mode == hive.Observe || c.Selection.Workspace != "" {
		// An explicit display client, observer or selection decides from
		// published discovery alone. It creates no state directory, never
		// contends for the owner lock and never starts a node of its own.
		if _, err := store.Read(ctx); errors.Is(err, os.ErrNotExist) {
			switch {
			case c.Mode == hive.Observe:
				return errors.New("No running Bee to observe; start bee first")
			case c.Selection.Workspace != "":
				return errors.New("No running Bee for the selected desktop; start bee first")
			default:
				return errors.New("No running Bee for this project; run bee to start its node")
			}
		} else if err != nil {
			return err
		}
		return c.Attach(ctx, launch)
	}
	if err := privatefile.EnsurePrivateDir(launch.State); err != nil {
		return err
	}
	// The runtime's application lock is the ownership authority. Owned is a
	// snapshot that creates nothing, so an absent state stays absent.
	busy, err := app.Owned(launch.State)
	if err != nil {
		return err
	}
	if busy {
		// The runtime lock is only a routing hint. Attach independently
		// authenticates the owner; refusal never starts a competing owner.
		return c.Attach(ctx, launch)
	}
	previous, err := store.Read(ctx)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := privatefile.EnsurePrivateDir(launch.State); err != nil {
		return err
	}
	log, err := os.CreateTemp(launch.State, "owner-*.log")
	if err != nil {
		return err
	}
	defer log.Close()
	if err := privatefile.SetOwnerOnlyPermissions(log.Name()); err != nil {
		return err
	}
	child, err := StartOwner(ctx, launch, log)
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
	if err := c.Attach(ctx, launch); err != nil {
		return fmt.Errorf("Bee client attachment (owner log %s): %w", log.Name(), err)
	}
	return nil
}

func waitOwnerPublication(ctx context.Context, read func(context.Context) (rendezvous.Descriptor, error), previous rendezvous.Descriptor, done <-chan struct{}, wait func(context.Context) error) error {
	tick := time.NewTicker(25 * time.Millisecond)
	defer tick.Stop()
	var childErr error
	childFinished := false
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		if !childFinished {
			select {
			case <-done:
				childErr = wait(ctx)
				childFinished = true
			default:
			}
		}
		current, err := read(ctx)
		if err == nil && current != previous {
			// The descriptor is only a fresh routing hint. Attach performs the
			// actual owner authentication and can still refuse it.
			return nil
		}
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			if childFinished {
				return errors.Join(childErr, err)
			}
			return err
		}
		if childFinished && !errors.Is(childErr, app.ErrOwned) {
			return childErr
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-done:
			if !childFinished {
				childErr = wait(ctx)
				childFinished = true
			}
		case <-tick.C:
		}
	}
}
