//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"os"
	"path/filepath"

	"github.com/wippyai/bee/native/client/hive"
	"github.com/wippyai/bee/native/client/session"
	"github.com/wippyai/bee/native/hive/rendezvous"
	app "github.com/wippyai/runtime/cmd/app"
)

// runClientRoute is the production client route: ensure the retained owner
// exists, enroll this process's identity and join the owner's mesh. Ctrl-Q ends
// only this process.
func runClientRoute(ctx context.Context, launch app.Launch) error {
	return runClientEnsuresOwner(ctx, launch, defaultClientSeams(), joinRequest{})
}

func defaultClientSeams() clientSeams {
	return clientSeams{
		owned:          app.Owned,
		startOwner:     startDetachedOwner,
		waitDescriptor: readDescriptor,
		join:           joinOwner,
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
// retained desktop.
func joinOwner(ctx context.Context, join joinRequest) error {
	return session.Join(ctx, session.Config{Directory: join.Directory, Mode: hive.Control}, os.Stdin, os.Stdout)
}

// startDetachedOwner starts `bee --state <state> start` in its own session so the
// owner outlives this client.
func startDetachedOwner(ctx context.Context, launch app.Launch) (<-chan struct{}, func() error, error) {
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
	done, wait, err := startDetachedCommand(ctx, execOwnerCommand(executable, launch, log))
	if err != nil {
		_ = log.Close()
		return nil, nil, err
	}
	return done, func() error { defer func() { _ = log.Close() }(); return wait() }, nil
}
