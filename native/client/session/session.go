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

// Selection pins an existing durable display in one workspace. Empty attaches
// the owner's folder workspace, or lets the person pick one of the node's
// workspaces when the owner composes none. Discovery order never chooses among
// workspaces.
type Selection struct{ Workspace, Desktop string }

// Detach waits for the owner's acknowledgement, including under scheduler
// load. This bound diagnoses a stalled owner; it is not an exit speed budget.
// The owner's monitor still owns eventual cleanup after an uncertain result.
const detachTimeout = 30 * time.Second

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

// selectDesktop checks an explicit selection against the node's displays. The
// workspace is the owner's to admit; the attach names it exactly.
func selectDesktop(catalog hive.DesktopCatalog, selection Selection) (Selection, error) {
	if (selection.Workspace == "") != (selection.Desktop == "") {
		return Selection{}, errors.New("workspace and desktop must be selected together")
	}
	for _, desktop := range catalog.Desktops {
		if desktop.ID == selection.Desktop {
			return selection, nil
		}
	}
	return Selection{}, errors.New("selected owner has no matching desktop")
}

type desktopOperations interface {
	Create(context.Context, string) (string, error)
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
func attachDesktop(ctx context.Context, client desktopOperations, catalog hive.DesktopCatalog, workspace string, selection Selection, mode hive.DesktopMode) (hive.DesktopMount, error) {
	if selection.Workspace != "" || selection.Desktop != "" {
		selected, err := selectDesktop(catalog, selection)
		if err != nil {
			return hive.DesktopMount{}, err
		}
		return client.Attach(ctx, "session-attach", selected.Workspace, selected.Desktop, mode)
	}
	if workspace == "" {
		return hive.DesktopMount{}, errors.New("no workspace selected; select a workspace and desktop")
	}
	for index, desktop := range catalog.Desktops {
		mounted, err := client.Attach(ctx, fmt.Sprintf("session-attach-%s-%d", workspace[:8], index), workspace, desktop.ID, mode)
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
	created, err := client.Create(ctx, desktop)
	if err != nil {
		return hive.DesktopMount{}, err
	}
	return client.Attach(ctx, "session-attach-created-"+created, workspace, created, mode)
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
// runs one Hive client of the owner's supervisor over the joined actor. It
// creates no desktop, viewport grant or controller session.
func Operate(ctx context.Context, cfg Config, node string, private ed25519.PrivateKey, run func(context.Context, *hive.Client, rendezvous.Descriptor) error) error {
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
			client, err := hive.NewClient(frame, actor, owner.Node)
			if err != nil {
				return err
			}
			return run(frame, client, owner)
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

// present attaches the selected workspace, the owner's folder workspace, or,
// when the owner composes none, the workspaces the person picks: each local
// detach (Ctrl+]) returns to the picker and Ctrl+Q leaves.
func present(ctx context.Context, foreground context.Context, actor *mesh.Actor, owner rendezvous.Descriptor, cfg Config, stdin *os.File, stdout io.Writer) error {
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
	settled := func(err error) error {
		if errors.Is(err, physical.ErrDetached) {
			return nil
		}
		return err
	}
	if cfg.Selection.Workspace != "" {
		return settled(presentWorkspace(ctx, operations, client, catalog, cfg.Selection.Workspace, cfg.Selection, cfg, cfg.Command, stdin, stdout))
	}
	if catalog.Default != "" {
		return settled(presentWorkspace(ctx, operations, client, catalog, catalog.Default, Selection{}, cfg, cfg.Command, stdin, stdout))
	}
	reads := 0
	list := func(ctx context.Context, query hive.CatalogQuery) (hive.DesktopCatalog, error) {
		reads++
		return client.List(ctx, fmt.Sprintf("session-picker-%d", reads), query)
	}
	command := cfg.Command
	for {
		workspace, err := pick(operations, list, stdin, stdout)
		if errors.Is(err, ErrPickerClosed) {
			return nil
		}
		if err != nil {
			return err
		}
		// Displays belong to the node; reread them, since an earlier
		// workspace may have allocated one.
		current, err := list(operations, hive.CatalogQuery{})
		if err != nil {
			return err
		}
		err = presentWorkspace(ctx, operations, client, current, workspace, Selection{}, cfg, command, stdin, stdout)
		command = nil
		if !errors.Is(err, physical.ErrDetached) {
			return err
		}
	}
}

// presentWorkspace attaches one display of one workspace, presents it until it
// ends and detaches it. When the display is switched to another workspace from
// inside the desktop, its old mount ends; the presentation continues with the
// client's new session on the same display.
func presentWorkspace(ctx context.Context, operations context.Context, client *hive.Desktop, catalog hive.DesktopCatalog, workspace string,
	selection Selection, cfg Config, command *hive.DesktopCommand, stdin *os.File, stdout io.Writer) (result error) {
	mounted, err := attachDesktop(operations, client, catalog, workspace, selection, cfg.Mode)
	if err != nil {
		return err
	}
	defer func() {
		// Once the bounded transport grace expires this actor is retired.
		// Otherwise detach explicitly before normal native actor shutdown.
		if ctx.Err() != nil {
			return
		}
		if err := detachMounted(ctx, client, mounted); err != nil {
			result = errors.Join(result, fmt.Errorf("detach desktop: %w", err))
		}
	}()
	if command != nil {
		if _, err := client.Launch(operations, "session-launch", mounted, *command); err != nil {
			return err
		}
	}
	reads := 0
	current := func(ctx context.Context) (hive.DesktopMount, error) {
		reads++
		return client.Current(ctx, fmt.Sprintf("session-current-%d", reads), mounted)
	}
	for {
		err := presentMount(ctx, operations, client, mounted, cfg, stdin, stdout)
		next, followed := followSwitch(operations, current, mounted, err)
		if !followed {
			return err
		}
		mounted = next
	}
}

type desktopDetacher interface {
	Detach(context.Context, string, hive.DesktopMount) error
}

func detachMounted(ctx context.Context, client desktopDetacher, mounted hive.DesktopMount) error {
	cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), detachTimeout)
	defer cancel()
	return client.Detach(cleanup, "session-detach-"+mounted.Session, mounted)
}

// followSwitch asks for the client's current session after a presentation
// ended on its own, not by a local detach, leave or cancellation. A new session
// means the display now shows another workspace.
func followSwitch(ctx context.Context, current func(context.Context) (hive.DesktopMount, error), mounted hive.DesktopMount, ended error) (hive.DesktopMount, bool) {
	if ended == nil || errors.Is(ended, physical.ErrDetached) || ctx.Err() != nil {
		return hive.DesktopMount{}, false
	}
	next, err := current(ctx)
	if err != nil || next.Session == mounted.Session {
		return hive.DesktopMount{}, false
	}
	return next, true
}

// presentMount presents one mount until it ends.
func presentMount(ctx context.Context, operations context.Context, client *hive.Desktop, mounted hive.DesktopMount, cfg Config,
	stdin *os.File, stdout io.Writer) error {
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
		selected, err := client.Copy(request, fmt.Sprintf("session-copy-%s-%d", mounted.Session, copySequence), mounted)
		var rejected *hive.Rejected
		if errors.As(err, &rejected) && rejected.Fault.Code == "INVALID_STATE" {
			return "", false, physical.ErrCopyRefused
		}
		return selected.Text, selected.Selected, err
	}
	if err := physical.RunWithCopy(display, remote, rights, stdin, stdout, copySelection); err != nil {
		if errors.Is(err, physical.ErrDetached) {
			return err
		}
		return fmt.Errorf("present desktop: %w", err)
	}
	return nil
}

// waitCatalog tolerates an owner still starting, within the caller's discovery
// deadline. Each read gets a fresh key so a cached refusal cannot pin readiness.
// It never retries authorization, protocol, transport or uncertain failures.
func waitCatalog(ctx context.Context, list func(context.Context, string, hive.CatalogQuery) (hive.DesktopCatalog, error)) (hive.DesktopCatalog, error) {
	for attempt := 0; ; attempt++ {
		if err := ctx.Err(); err != nil {
			return hive.DesktopCatalog{}, err
		}
		catalog, err := list(ctx, fmt.Sprintf("session-catalog-%d", attempt), hive.CatalogQuery{})
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
