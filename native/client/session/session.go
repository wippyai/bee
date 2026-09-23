//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT

// Package session composes native client enrollment, supervisor admission and
// physical presentation. It never starts an owner or opens application stores.
package session

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/wippyai/bee/native/client/hive"
	"github.com/wippyai/bee/native/client/mesh"
	"github.com/wippyai/bee/native/client/physical"
	"github.com/wippyai/bee/native/hive/rendezvous"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/api/tty"
	stackpkg "github.com/wippyai/runtime/cluster"
	"github.com/wippyai/runtime/cluster/internode"
)

// Selection pins an existing durable display. Empty lets an ordinary local Bee
// reuse the first uncontrolled display or allocate a new one in its sole
// project workspace. Discovery order never chooses among workspaces.
type Selection struct{ Workspace, Desktop string }

// Physical detach must not wait for the normal operation deadline. If the
// owner cannot acknowledge promptly, report uncertainty and retire this actor;
// the owner's monitor still owns eventual attachment cleanup.
const detachTimeout = 200 * time.Millisecond

type Config struct {
	// Directory holds the owner's rendezvous descriptor.
	Directory string
	// EnrollmentDir holds the owner-seeded local enrollment.
	EnrollmentDir string
	// TLS is the owner's mesh credential, shared by its local clients.
	TLS       internode.ManagerTLSConfig
	Selection Selection
	Command   *hive.DesktopCommand
	Mode      hive.DesktopMode
}

func (cfg Config) join(node string, private ed25519.PrivateKey) mesh.JoinConfig {
	return mesh.JoinConfig{Directory: cfg.Directory, EnrollmentDirectory: cfg.EnrollmentDir, Node: node, Key: private, TLS: cfg.TLS}
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

type desktopOperations interface {
	Create(context.Context, string, string) (hive.DesktopSelection, error)
	Attach(context.Context, string, string, string, hive.DesktopMode) (hive.DesktopMount, error)
}

func randomDesktopID() (string, error) {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(value[:]), nil
}

// attachDesktop makes ordinary local launch useful with several terminals. It
// only retries after the owner definitively says an existing display already
// has another controller. Unknown outcomes and every other refusal return
// immediately. Explicit selections remain exact and never allocate.
func attachDesktop(ctx context.Context, client desktopOperations, catalog hive.DesktopCatalog, selection Selection, mode hive.DesktopMode) (hive.DesktopMount, error) {
	if selection.Workspace != "" || selection.Desktop != "" {
		selected, err := selectDesktop(catalog, selection)
		if err != nil {
			return hive.DesktopMount{}, err
		}
		return client.Attach(ctx, "session-attach", selected.Workspace, selected.Desktop, mode)
	}
	if len(catalog.Workspaces) != 1 {
		return hive.DesktopMount{}, errors.New("multiple workspaces available; select a workspace and desktop")
	}
	workspace := catalog.Workspaces[0]
	for index, desktop := range workspace.Desktops {
		mounted, err := client.Attach(ctx, fmt.Sprintf("session-attach-%d", index), workspace.ID, desktop.ID, mode)
		if err == nil {
			return mounted, nil
		}
		var rejected *hive.Rejected
		if mode != hive.Control || !errors.As(err, &rejected) || rejected.Fault.Code != "DESKTOP_CONTROLLED" {
			return hive.DesktopMount{}, err
		}
	}
	if mode != hive.Control {
		return hive.DesktopMount{}, errors.New("selected owner has no display to observe")
	}
	desktop, err := randomDesktopID()
	if err != nil {
		return hive.DesktopMount{}, err
	}
	created, err := client.Create(ctx, workspace.ID, desktop)
	if err != nil {
		return hive.DesktopMount{}, err
	}
	return client.Attach(ctx, "session-attach-created", created.Workspace, created.Desktop, mode)
}

// JoinEnrolled joins an owner whose local enrollment already lists node with the
// supplied private key, over loopback with the owner's mesh credential, and
// presents the selected desktop until local detach, cancellation or an
// operation failure. The caller owns the physical files and signal context.
// Input and mutations are never replayed, and every request still goes
// through the owner supervisor. It never starts an owner or opens application
// stores.
func JoinEnrolled(ctx context.Context, cfg Config, node string, private ed25519.PrivateKey, stdin *os.File, stdout io.Writer) error {
	if ctx == nil || stdin == nil || stdout == nil || cfg.Directory == "" || cfg.EnrollmentDir == "" || node == "" ||
		len(private) != ed25519.PrivateKeySize ||
		(cfg.Mode != hive.Control && cfg.Mode != hive.Observe) ||
		((cfg.Selection.Workspace == "") != (cfg.Selection.Desktop == "")) ||
		(cfg.Command != nil && (!cfg.Command.Valid() || cfg.Mode != hive.Control)) {
		return errors.New("invalid enrolled client session configuration")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	transport, closeTransport := cleanupLifetime(ctx)
	defer closeTransport()
	return mesh.Joined(transport, cfg.join(node, private), func(lifetime context.Context, stack *stackpkg.Stack, owner rendezvous.Descriptor) error {
		return mesh.WithActor(lifetime, stack, owner.Node, func(frame context.Context, actor *mesh.Actor) error {
			pinSupervisor(actor, owner)
			return present(frame, ctx, actor, owner, cfg, stdin, stdout)
		})
	})
}

// ListEnrolled reads the durable desktop identities of an owner whose local
// enrollment lists node with this key. It creates no desktop, viewport grant or
// controller session.
func ListEnrolled(ctx context.Context, cfg Config, node string, private ed25519.PrivateKey) (hive.DesktopCatalog, error) {
	var catalog hive.DesktopCatalog
	if ctx == nil || cfg.Directory == "" || cfg.EnrollmentDir == "" || node == "" || len(private) != ed25519.PrivateKeySize {
		return catalog, errors.New("invalid enrolled desktop listing")
	}
	bounded, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	err := mesh.Joined(bounded, cfg.join(node, private), func(lifetime context.Context, stack *stackpkg.Stack, owner rendezvous.Descriptor) error {
		return mesh.WithActor(lifetime, stack, owner.Node, func(frame context.Context, actor *mesh.Actor) error {
			pinSupervisor(actor, owner)
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

// Operate joins an owner whose local enrollment lists node with this key and
// runs one Hive join client over the joined actor. It creates no desktop,
// viewport grant or controller session.
func Operate(ctx context.Context, cfg Config, node string, private ed25519.PrivateKey, run func(context.Context, *hive.Join, rendezvous.Descriptor) error) error {
	if ctx == nil || run == nil || cfg.Directory == "" || cfg.EnrollmentDir == "" || node == "" || len(private) != ed25519.PrivateKeySize {
		return errors.New("invalid enrolled Hive operation")
	}
	bounded, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	return mesh.Joined(bounded, cfg.join(node, private), func(lifetime context.Context, stack *stackpkg.Stack, owner rendezvous.Descriptor) error {
		return mesh.WithActor(lifetime, stack, owner.Node, func(frame context.Context, actor *mesh.Actor) error {
			pinSupervisor(actor, owner)
			if err := awaitSupervisor(frame, actor); err != nil {
				return err
			}
			join, err := hive.NewJoin(frame, actor, owner.Node)
			if err != nil {
				return err
			}
			return run(frame, join, owner)
		})
	})
}

// awaitSupervisor waits until the owner supervisor is addressable.
func awaitSupervisor(ctx context.Context, actor *mesh.Actor) error {
	ready, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	tick := time.NewTicker(50 * time.Millisecond)
	defer tick.Stop()
	for {
		if _, err := actor.OwnerSupervisor(ready); err == nil {
			return nil
		}
		select {
		case <-ready.Done():
			return fmt.Errorf("discover owner supervisor: %w", ready.Err())
		case <-tick.C:
		}
	}
}

// pinSupervisor addresses the owner's supervisor directly. The descriptor
// publishes its address because a raft-disabled owner never registers the
// cluster-wide name; OwnerSupervisor still verifies node, host and identity.
func pinSupervisor(actor *mesh.Actor, owner rendezvous.Descriptor) {
	if owner.Supervisor == "" {
		return
	}
	if address, err := pid.ParsePID(owner.Supervisor); err == nil {
		actor.PinSupervisor(address)
	}
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
	mounted, err := attachDesktop(operations, client, catalog, cfg.Selection, cfg.Mode)
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

func readyDesktop(ctx context.Context, operations context.Context, actor *mesh.Actor, owner rendezvous.Descriptor) (*hive.Desktop, hive.DesktopCatalog, error) {
	ready, cancelReady := context.WithTimeout(operations, 15*time.Second)
	defer cancelReady()
	if err := awaitSupervisor(ready, actor); err != nil {
		return nil, hive.DesktopCatalog{}, err
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
