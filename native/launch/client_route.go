//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"crypto/ed25519"
	"errors"
	"os"
	"path/filepath"
	"time"

	"github.com/wippyai/bee/native/client/hive"
	"github.com/wippyai/bee/native/client/mesh"
	"github.com/wippyai/bee/native/client/session"
	"github.com/wippyai/bee/native/hive/rendezvous"
	app "github.com/wippyai/runtime/cmd/app"
)

var _ = mesh.Local

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
		waitEnrolled:   waitEnrolled,
		report:         os.Stdout,
	}
}

// waitEnrolled polls the owner-seeded enrollment until it lists the client node.
func waitEnrolled(ctx context.Context, state, node string) error {
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
			if _, ok := enrollment.Resolve(ctx, descriptor.Execution, node); ok {
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
// retained desktop, using the exact node identity it enrolled. The owner seeded
// that key, so the join is plaintext loopback with the pinned identity.
func joinOwner(ctx context.Context, join joinRequest) error {
	if len(join.Key) != ed25519.PrivateKeySize {
		return errors.New("client identity is missing")
	}
	// The rendezvous directory holds the published join address; the owner
	// directory holds the enrollment the owner seeded. mesh.Joined reads both.
	return session.JoinEnrolled(ctx, session.Config{
		Directory:     join.Directory,
		EnrollmentDir: ownerDirectory(join.State),
		Mode:          hive.Control,
	}, join.Node, join.Key, os.Stdin, os.Stdout)
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
