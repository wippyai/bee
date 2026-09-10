//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT

// Package session composes native client enrollment, supervisor admission and
// physical presentation. It never starts an owner or opens application stores.
package session

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/wippyai/bee/native/client/hive"
	"github.com/wippyai/bee/native/client/mesh"
	"github.com/wippyai/bee/native/client/physical"
	"github.com/wippyai/bee/native/hive/rendezvous"
	"github.com/wippyai/runtime/api/tty"
	stackpkg "github.com/wippyai/runtime/cluster"
)

// Selection is explicit when more than one desktop is available. Empty selects
// the sole desktop only; discovery order must never choose a user's workspace.
type Selection struct{ Workspace, Desktop string }

// Physical detach must not wait for the normal operation deadline. If the
// owner cannot acknowledge promptly, report uncertainty and retire this actor;
// the owner's monitor still owns eventual attachment cleanup.
const detachTimeout = 200 * time.Millisecond

type Config struct {
	Directory string
	Selection Selection
	Mode      hive.DesktopMode
}

func selectDesktop(catalog hive.DesktopCatalog, selection Selection) (Selection, error) {
	if (selection.Workspace == "") != (selection.Desktop == "") {
		return Selection{}, errors.New("workspace and desktop must be selected together")
	}
	var found Selection
	count := 0
	for _, workspace := range catalog.Workspaces {
		for _, desktop := range workspace.Desktops {
			candidate := Selection{Workspace: workspace.ID, Desktop: desktop.ID}
			if selection.Workspace != "" && candidate != selection {
				continue
			}
			found = candidate
			count++
		}
	}
	if count == 0 {
		return Selection{}, errors.New("selected owner has no matching desktop")
	}
	if count != 1 {
		return Selection{}, errors.New("multiple desktops available; select a workspace and desktop")
	}
	return found, nil
}

// Join runs until local detach, cancellation or an operation failure. The caller
// owns the physical files and signal context. Input and mutations are never
// replayed, and every request still goes through the discovered owner supervisor.
func Join(ctx context.Context, cfg Config, stdin *os.File, stdout io.Writer) error {
	if ctx == nil || stdin == nil || stdout == nil || cfg.Directory == "" ||
		(cfg.Mode != hive.Control && cfg.Mode != hive.Observe) ||
		((cfg.Selection.Workspace == "") != (cfg.Selection.Desktop == "")) {
		return errors.New("invalid native client session configuration")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	transport, closeTransport := cleanupLifetime(ctx)
	defer closeTransport()
	return mesh.SameAccount(transport, cfg.Directory, func(lifetime context.Context, stack *stackpkg.Stack, owner rendezvous.Descriptor) error {
		return mesh.WithActor(lifetime, stack, owner.Node, func(frame context.Context, actor *mesh.Actor) error {
			return present(frame, ctx, actor, owner, cfg, stdin, stdout)
		})
	})
}

func present(ctx context.Context, foreground context.Context, actor *mesh.Actor, owner rendezvous.Descriptor, cfg Config, stdin *os.File, stdout io.Writer) (result error) {
	operations, cancelOperations := context.WithCancel(ctx)
	stopForeground := context.AfterFunc(foreground, cancelOperations)
	defer stopForeground()
	defer cancelOperations()
	if err := foreground.Err(); err != nil {
		return err
	}
	client, catalog, err := readyDesktop(ctx, operations, actor, owner)
	if err != nil {
		return err
	}
	selected, err := selectDesktop(catalog, cfg.Selection)
	if err != nil {
		return err
	}
	mounted, err := client.Attach(operations, "session-attach", selected.Workspace, selected.Desktop, cfg.Mode)
	if err != nil {
		return err
	}
	defer func() {
		// Once the bounded transport grace expires this actor is retired.
		// Otherwise detach explicitly before normal native actor shutdown.
		if ctx.Err() != nil {
			return
		}
		cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), detachTimeout)
		defer cancel()
		if err := client.Detach(cleanup, "session-detach", mounted); err != nil {
			result = errors.Join(result, fmt.Errorf("detach desktop: %w", err))
		}
	}()
	service := tty.GetService(ctx)
	if service == nil {
		return errors.New("native viewport service unavailable")
	}
	view, err := service.Attach(ctx, mounted.Mount)
	if err != nil {
		return err
	}
	defer view.Close()
	remote, ok := view.(physical.Viewport)
	if !ok {
		return errors.New("native viewport lacks physical presentation interface")
	}
	display, cancelDisplay := context.WithDeadline(operations, mounted.Expires)
	defer cancelDisplay()
	rights := tty.MountRights{Observe: true, Input: cfg.Mode == hive.Control, Resize: cfg.Mode == hive.Control}
	copySequence := uint64(0) // accessed only by the serialized physical input worker
	copySelection := func(ctx context.Context) (string, bool, error) {
		copySequence++
		request, cancel := context.WithTimeout(ctx, 3*time.Second)
		defer cancel()
		selected, err := client.Copy(request, fmt.Sprintf("session-copy-%d", copySequence), mounted)
		var rejected *hive.Rejected
		if errors.As(err, &rejected) && rejected.Fault.Code == "INVALID_STATE" {
			return "", false, physical.ErrCopyRefused
		}
		return selected.Text, selected.Selected, err
	}
	if err := physical.RunWithCopy(display, remote, rights, stdin, stdout, copySelection); err != nil {
		return fmt.Errorf("present desktop: %w", err)
	}
	return nil
}

// waitCatalog tolerates an owner still starting, within the caller's discovery
// deadline. Each read gets a fresh key so a cached refusal cannot pin readiness.
// It never retries authorization, protocol, transport or uncertain failures.
func waitCatalog(ctx context.Context, list func(context.Context, string) (hive.DesktopCatalog, error)) (hive.DesktopCatalog, error) {
	for attempt := 0; ; attempt++ {
		if err := ctx.Err(); err != nil {
			return hive.DesktopCatalog{}, err
		}
		catalog, err := list(ctx, fmt.Sprintf("session-catalog-%d", attempt))
		if err == nil {
			return catalog, nil
		}
		rejected, ok := err.(*hive.Rejected)
		if !ok || rejected.Fault.Code != "UNAVAILABLE" {
			return hive.DesktopCatalog{}, err
		}
		timer := time.NewTimer(50 * time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			return hive.DesktopCatalog{}, fmt.Errorf("wait for desktop catalog (%v): %w", err, ctx.Err())
		case <-timer.C:
		}
	}
}

// Probe authenticates the owner and reads its catalog without creating a desktop
// attachment. It is used by an explicit start that loses the runtime lock race.
// Successful lock contention alone is never reported as an available owner.
func Probe(ctx context.Context, directory string) error {
	if ctx == nil || directory == "" {
		return errors.New("invalid owner probe")
	}
	bounded, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	store, err := rendezvous.New(directory)
	if err != nil {
		return err
	}
	if err := awaitPublication(bounded, store.Read); err != nil {
		return err
	}
	return mesh.SameAccount(bounded, directory, func(lifetime context.Context, stack *stackpkg.Stack, owner rendezvous.Descriptor) error {
		return mesh.WithActor(lifetime, stack, owner.Node, func(frame context.Context, actor *mesh.Actor) error {
			_, _, err := readyDesktop(frame, frame, actor, owner)
			return err
		})
	})
}

func readyDesktop(ctx context.Context, operations context.Context, actor *mesh.Actor, owner rendezvous.Descriptor) (*hive.Desktop, hive.DesktopCatalog, error) {
	ready, cancelReady := context.WithTimeout(operations, 15*time.Second)
	defer cancelReady()
	tick := time.NewTicker(50 * time.Millisecond)
	defer tick.Stop()
	for {
		if _, err := actor.OwnerSupervisor(ready); err == nil {
			break
		}
		select {
		case <-ready.Done():
			return nil, hive.DesktopCatalog{}, fmt.Errorf("discover owner supervisor: %w", ready.Err())
		case <-tick.C:
		}
	}
	client, err := hive.NewDesktop(ctx, actor, owner.Node, owner.Execution)
	if err != nil {
		return nil, hive.DesktopCatalog{}, err
	}
	// A fresh actor has its own owner-qualified request/idempotency namespace.
	catalog, err := waitCatalog(ready, client.List)
	if err != nil {
		return nil, hive.DesktopCatalog{}, err
	}
	return client, catalog, nil
}

// The winner may hold the application lock before publishing discovery. Waiting
// reads only; it creates no files, enrollments or desktop attachments. A decoded
// descriptor remains only a hint and is authenticated by SameAccount afterward.
func awaitPublication(ctx context.Context, read func(context.Context) (rendezvous.Descriptor, error)) error {
	tick := time.NewTicker(25 * time.Millisecond)
	defer tick.Stop()
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		_, err := read(ctx)
		if err == nil {
			return nil
		}
		if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-tick.C:
		}
	}
}

// Keep native admission alive briefly after foreground cancellation so the
// physical surface can restore its terminal and commit detach before actor exit.
// Startup and stalled cleanup remain bounded; Close joins the cancellation hook.
func cleanupLifetime(foreground context.Context) (context.Context, func()) {
	transport, cancel := context.WithCancel(context.WithoutCancel(foreground))
	finished, callbackDone := make(chan struct{}), make(chan struct{})
	stop := context.AfterFunc(foreground, func() {
		defer close(callbackDone)
		timer := time.NewTimer(3 * time.Second)
		defer timer.Stop()
		select {
		case <-finished:
		case <-timer.C:
			cancel()
		}
	})
	return transport, func() {
		close(finished)
		cancel()
		if !stop() {
			<-callbackDone
		}
	}
}
