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
// the sole desktop or one workspace's explicitly declared default; discovery
// order must never choose a user's workspace.
type Selection struct{ Workspace, Desktop string }

// Physical detach must not wait for the normal operation deadline. If the
// owner cannot acknowledge promptly, report uncertainty and retire this actor;
// the owner's monitor still owns eventual attachment cleanup.
const detachTimeout = time.Second

// ErrOwnerUnavailable means native mesh authentication did not reach the
// published owner. It is emitted before supervisor admission or any desktop
// request, so a launcher may let a detached contender ask cmd/app to arbitrate
// state ownership. It never describes an admission refusal or mutation result.
var ErrOwnerUnavailable = errors.New("published Bee owner is unavailable")

type Config struct {
	Directory string
	Selection Selection
	Command   *hive.DesktopCommand
	Mode      hive.DesktopMode
}

func selectDesktop(catalog hive.DesktopCatalog, selection Selection) (Selection, error) {
	if (selection.Workspace == "") != (selection.Desktop == "") {
		return Selection{}, errors.New("workspace and desktop must be selected together")
	}
	if selection == (Selection{}) && len(catalog.Workspaces) == 1 {
		workspace := catalog.Workspaces[0]
		defaults := 0
		var selected Selection
		for _, desktop := range workspace.Desktops {
			if desktop.IsDefault {
				defaults++
				selected = Selection{Workspace: workspace.ID, Desktop: desktop.ID}
			}
		}
		if defaults == 1 {
			return selected, nil
		}
		if defaults > 1 {
			return Selection{}, errors.New("desktop catalog has multiple defaults")
		}
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
		((cfg.Selection.Workspace == "") != (cfg.Selection.Desktop == "")) ||
		(cfg.Command != nil && (!cfg.Command.Valid() || cfg.Mode != hive.Control)) {
		return errors.New("invalid native client session configuration")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	// Another ordinary launch may already hold the runtime lock while its
	// owner is still preparing. Wait for its discovery publication before
	// entering native authentication; absence is not a reason to start a peer.
	store, err := rendezvous.New(cfg.Directory)
	if err != nil {
		return err
	}
	publication, cancelPublication := context.WithTimeout(ctx, 15*time.Second)
	err = awaitPublication(publication, store.Read)
	cancelPublication()
	if err != nil {
		return fmt.Errorf("wait for owner discovery: %w", err)
	}
	transport, closeTransport := cleanupLifetime(ctx)
	defer closeTransport()
	reachedOwner := false
	err = mesh.SameAccount(transport, cfg.Directory, func(lifetime context.Context, stack *stackpkg.Stack, owner rendezvous.Descriptor) error {
		reachedOwner = true
		return mesh.WithActor(lifetime, stack, owner.Node, func(frame context.Context, actor *mesh.Actor) error {
			return present(frame, ctx, actor, owner, cfg, stdin, stdout)
		})
	})
	if err != nil && !reachedOwner {
		return fmt.Errorf("%w: %v", ErrOwnerUnavailable, err)
	}
	return err
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
	admission, cancelAdmission := context.WithTimeout(operations, 60*time.Second)
	mounted, err := attachDesktop(admission, client, catalog, cfg.Selection, cfg.Mode)
	cancelAdmission()
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
	if cfg.Command != nil {
		if _, err := client.Launch(operations, "session-launch", mounted, *cfg.Command); err != nil {
			return err
		}
	}
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

// waitCatalog tolerates an owner still starting or a busy catalog reader, within the caller's discovery
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
		if !ok || (rejected.Fault.Code != "UNAVAILABLE" && rejected.Fault.Code != "BUSY") {
			// This operation reads the catalog. No attachment has been sent,
			// so a canceled read is not an uncertain desktop mutation.
			if errors.Is(err, context.Canceled) {
				return hive.DesktopCatalog{}, fmt.Errorf("Bee launch canceled before desktop attachment: %w", context.Canceled)
			}
			if errors.Is(err, context.DeadlineExceeded) {
				return hive.DesktopCatalog{}, fmt.Errorf("running Bee owner did not answer; no desktop attachment requested: %w", context.DeadlineExceeded)
			}
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
	_, err := readCatalog(ctx, directory, 15*time.Second)
	return err
}

// List authenticates the selected Bee and reads its durable desktop identities.
// It creates no desktop, viewport grant or controller session.
func List(ctx context.Context, directory string) (hive.DesktopCatalog, error) {
	return readCatalog(ctx, directory, 60*time.Second)
}

func readCatalog(ctx context.Context, directory string, timeout time.Duration) (hive.DesktopCatalog, error) {
	var catalog hive.DesktopCatalog
	if ctx == nil || directory == "" {
		return catalog, errors.New("invalid owner probe")
	}
	bounded, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	store, err := rendezvous.New(directory)
	if err != nil {
		return catalog, err
	}
	if err := awaitPublication(bounded, store.Read); err != nil {
		return catalog, err
	}
	err = mesh.SameAccount(bounded, directory, func(lifetime context.Context, stack *stackpkg.Stack, owner rendezvous.Descriptor) error {
		return mesh.WithActor(lifetime, stack, owner.Node, func(frame context.Context, actor *mesh.Actor) error {
			_, result, err := readyDesktop(frame, frame, actor, owner)
			if err == nil {
				catalog = result
			}
			return err
		})
	})
	if err != nil {
		return hive.DesktopCatalog{}, err
	}
	return catalog, nil
}

func readyDesktop(ctx context.Context, operations context.Context, actor *mesh.Actor, owner rendezvous.Descriptor) (*hive.Desktop, hive.DesktopCatalog, error) {
	ready, cancelReady := context.WithTimeout(operations, 60*time.Second)
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
