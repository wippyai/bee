//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"crypto/ed25519"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/wippyai/bee/native/client/hive"
	"github.com/wippyai/bee/native/client/session"
	"github.com/wippyai/bee/native/hive/meshtls"
	"github.com/wippyai/bee/native/hive/rendezvous"
	app "github.com/wippyai/runtime/cmd/app"
)

// runClientRoute is the production client route: ensure the retained owner
// exists, enroll this process's identity and join the owner's mesh. Ctrl-Q ends
// only this process.
func runClientRoute(ctx context.Context, launch app.Launch, intent clientIntent) error {
	return runClientEnsuresOwner(ctx, launch, defaultClientSeams(), joinRequest{Intent: intent})
}

// intentCommand is the application launch the joined session submits.
func intentCommand(intent clientIntent) hive.DesktopCommand {
	return hive.DesktopCommand{Name: intent.command[0], Arguments: append([]string{}, intent.command[1:]...)}
}

func defaultClientSeams() clientSeams {
	return clientSeams{
		owned:          app.Owned,
		startOwner:     startDetachedOwner,
		waitDescriptor: readDescriptor,
		join:           joinOwner,
		waitEnrolled:   waitEnrolled,
		report:         os.Stdout,
		released:       waitReleased,
	}
}

// waitEnrolled polls the owner-seeded enrollment until it lists the client node
// with this client's key.
func waitEnrolled(ctx context.Context, state, node string, public ed25519.PublicKey) error {
	enrollment, err := rendezvous.NewEnrollment(ownerDirectory(state))
	if err != nil {
		return err
	}
	deadline := time.Now().Add(waitOwnerTimeout)
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		descriptor, err := readDescriptor(ctx, filepath.Join(state, rendezvous.DirectoryName))
		if err == nil {
			if key, ok := enrollment.Resolve(ctx, descriptor.Execution, node); ok && key.Equal(public) {
				return nil
			}
		}
		if time.Now().After(deadline) {
			return errors.New("owner did not enroll this client before the timeout")
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(waitPollInterval):
		}
	}
}

func readDescriptor(ctx context.Context, directory string) (rendezvous.Descriptor, error) {
	store, err := rendezvous.New(directory)
	if err != nil {
		return rendezvous.Descriptor{}, err
	}
	return store.Read(ctx)
}

// joinOwner boots the client against the owner's published mesh and presents the
// retained desktop, or runs a `bee hive` command, using the exact node identity
// it enrolled. The owner seeded that key; the join is loopback with the pinned
// identity and the owner's mesh credential.
func joinOwner(ctx context.Context, join joinRequest) error {
	if len(join.Key) != ed25519.PrivateKeySize {
		return errors.New("client identity is missing")
	}
	// The rendezvous directory holds the published join address; the owner
	// directory holds the enrollment the owner seeded and its mesh credential.
	config := session.Config{
		Directory:     join.Directory,
		EnrollmentDir: ownerDirectory(join.State),
		TLS:           meshtls.Config(ownerDirectory(join.State)),
		Selection:     session.Selection{Workspace: join.Intent.workspace, Desktop: join.Intent.desktop},
		Mode:          hive.Control,
	}
	if join.Intent.hive != nil {
		command := *join.Intent.hive
		return session.Operate(ctx, config, join.Node, join.Key, func(ctx context.Context, client *hive.Client, _ rendezvous.Descriptor) error {
			return runHive(ctx, os.Stdout, hive.JoinOver(client), join.Directory, command)
		})
	}
	if join.Intent.stop {
		alone := join.Intent.alone
		return session.Operate(ctx, config, join.Node, join.Key, func(ctx context.Context, client *hive.Client, _ rendezvous.Descriptor) error {
			_, err := hive.StopOwner(ctx, client, alone)
			return err
		})
	}
	if join.Intent.catalog != nil {
		command := *join.Intent.catalog
		return session.Operate(ctx, config, join.Node, join.Key, func(ctx context.Context, client *hive.Client, _ rendezvous.Descriptor) error {
			return runWorkspace(ctx, os.Stdout, hive.WorkspacesOver(client), command)
		})
	}
	if join.Intent.observe {
		config.Mode = hive.Observe
	}
	if join.Intent.command != nil {
		command := intentCommand(join.Intent)
		config.Command = &command
	}
	if join.Intent.listing {
		catalog, err := session.ListEnrolled(ctx, config, join.Node, join.Key)
		if err != nil {
			return err
		}
		return printDesktops(os.Stdout, catalog)
	}
	err := session.JoinEnrolled(ctx, config, join.Node, join.Key, os.Stdin, os.Stdout)
	var rejected *hive.Rejected
	if config.Command != nil && errors.As(err, &rejected) && rejected.Fault.Code == "INVALID_ARGUMENT" {
		return &refusedCommand{cause: err}
	}
	return err
}

// printDesktops writes one line per display a client can attach: every node
// display in the folder workspace the owner composes, or, on a node without
// one, the node's default display in each workspace of the catalog's first
// page. Displays belong to the node; any of them attaches to any workspace.
func printDesktops(out io.Writer, catalog hive.DesktopCatalog) error {
	if _, err := fmt.Fprintln(out, "WORKSPACE                         DISPLAY                           DEFAULT"); err != nil {
		return err
	}
	row := func(workspace string, desktop hive.DesktopDescription) error {
		marker := ""
		if desktop.IsDefault {
			marker = "yes"
		}
		_, err := fmt.Fprintf(out, "%s  %s  %s\n", workspace, desktop.ID, marker)
		return err
	}
	if catalog.Default != "" {
		for _, desktop := range catalog.Desktops {
			if err := row(catalog.Default, desktop); err != nil {
				return err
			}
		}
		return nil
	}
	for _, workspace := range catalog.Workspaces {
		if err := row(workspace.ID, catalog.Desktops[0]); err != nil {
			return err
		}
	}
	if catalog.Next != "" {
		if _, err := fmt.Fprintln(out, "(more workspaces follow; run bee client to pick and search)"); err != nil {
			return err
		}
	}
	return nil
}

// startDetachedOwner starts `bee --state <state> start` in its own session so the
// owner outlives this client.
func startDetachedOwner(ctx context.Context, launch app.Launch, launchID string) (<-chan struct{}, func() error, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, nil, err
	}
	if !filepath.IsAbs(launch.State) || !filepath.IsAbs(launch.Dir) {
		return nil, nil, errRelativeOwnerLaunch
	}
	log, err := openOwnerLog(launch.State)
	if err != nil {
		return nil, nil, err
	}
	command := execOwnerCommand(executable, launch, log)
	command.Env = append(os.Environ(), ownerLaunchVariable+"="+launchID)
	done, wait, err := startDetachedCommand(ctx, command)
	if err != nil {
		_ = log.Close()
		return nil, nil, err
	}
	return done, func() error { defer func() { _ = log.Close() }(); return wait() }, nil
}
