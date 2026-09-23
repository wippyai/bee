// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/wippyai/bee/native/hive/rendezvous"
	"github.com/wippyai/bee/native/internal/privatefile"
	app "github.com/wippyai/runtime/cmd/app"
)

const (
	// attachmentKeyName is the client's per-attachment Ed25519 identity. It is
	// distinct from the owner identity and rotated per attachment.
	attachmentKeyName = "client.key"
	// waitOwnerTimeout bounds the wait for a freshly started owner to publish
	// its rendezvous descriptor.
	waitOwnerTimeout = 30 * time.Second
	// waitPollInterval is the rendezvous poll interval.
	waitPollInterval = 25 * time.Millisecond
)

// clientSeams are the side effects joining a client needs. Production supplies
// the real ones; tests substitute fakes to prove the sequence.
type clientSeams struct {
	owned          func(state string) (bool, error)
	startOwner     func(ctx context.Context, launch app.Launch) (done <-chan struct{}, wait func() error, err error)
	waitDescriptor func(ctx context.Context, directory string) (rendezvous.Descriptor, error)
	join           func(ctx context.Context, join joinRequest) error
	// waitEnrolled blocks until the owner has registered the client's node in the
	// local enrollment, or the context ends.
	waitEnrolled func(ctx context.Context, state, node string) error
	// report receives the foreground route line.
	report io.Writer
}

// joinRequest is the client's authenticated join into the owner's mesh.
type joinRequest struct {
	State     string
	Directory string
	Node      string
	Key       ed25519.PrivateKey
	Public    ed25519.PublicKey
	Owner     rendezvous.Descriptor
}

// runClientEnsuresOwner brings up or reuses the retained owner, enrolls this
// client's identity and joins the owner's mesh. It never starts a second owner:
// when the state is already owned it waits for the published descriptor and
// joins without spawning. Ctrl-Q ends only the joining runtime, never the owner.
func runClientEnsuresOwner(ctx context.Context, launch app.Launch, seams clientSeams, join joinRequest) error {
	if ctx == nil {
		return errors.New("client launch requires a context")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if !filepath.IsAbs(launch.State) || !filepath.IsAbs(launch.Dir) {
		return errors.New("client launch requires absolute state and project directories")
	}
	directory := filepath.Join(launch.State, rendezvous.DirectoryName)
	owned, err := seams.owned(launch.State)
	if err != nil {
		return err
	}
	// The route line describes routing only; the owner's publication and the
	// authenticated join still decide whether startup succeeds.
	route := "Starting Bee…"
	if owned {
		route = "Connecting to Hive…"
	}
	if _, err := fmt.Fprintln(seams.report, route); err != nil {
		return err
	}
	if !owned {
		done, wait, err := seams.startOwner(ctx, launch)
		if err != nil {
			return err
		}
		startup, cancel := context.WithTimeout(ctx, waitOwnerTimeout)
		defer cancel()
		if _, err := waitDescriptorOrExit(startup, seams.waitDescriptor, directory, done, wait); err != nil {
			return fmt.Errorf("Bee owner startup: %w", err)
		}
	}
	owner, err := seams.waitDescriptor(ctx, directory)
	if err != nil {
		return fmt.Errorf("Bee owner rendezvous: %w", err)
	}
	join.Directory = directory
	join.Owner = owner
	join.Node = clientNodeName(launch.State)
	if join.Key == nil {
		public, private, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			return err
		}
		join.Public, join.Key = public, private
	}
	if err := enrollClient(launch.State, directory, join.Node, join.Public); err != nil {
		return err
	}
	// The owner registers the trusted key on its own bounded refresh, so wait
	// until the enrollment lists this node before the mesh handshake.
	if seams.waitEnrolled != nil {
		if err := seams.waitEnrolled(ctx, launch.State, join.Node); err != nil {
			return err
		}
	}
	join.State = launch.State
	return seams.join(ctx, join)
}

// waitDescriptorOrExit waits for the descriptor a freshly started owner
// publishes, and fails as soon as the child exits without publishing.
func waitDescriptorOrExit(ctx context.Context, read func(context.Context, string) (rendezvous.Descriptor, error),
	directory string, done <-chan struct{}, wait func() error) (rendezvous.Descriptor, error) {
	tick := time.NewTicker(waitPollInterval)
	defer tick.Stop()
	for {
		if err := ctx.Err(); err != nil {
			return rendezvous.Descriptor{}, err
		}
		if descriptor, err := read(ctx, directory); err == nil {
			return descriptor, nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return rendezvous.Descriptor{}, err
		}
		if done != nil {
			select {
			case <-done:
				if wait != nil {
					if childErr := wait(); childErr != nil {
						return rendezvous.Descriptor{}, childErr
					}
				}
				return rendezvous.Descriptor{}, errors.New("Bee owner exited before publishing its rendezvous")
			default:
			}
		}
		select {
		case <-ctx.Done():
			return rendezvous.Descriptor{}, ctx.Err()
		case <-tick.C:
		}
	}
}

// clientNodeName derives a stable per-attachment node name for the client.
func clientNodeName(state string) string {
	digest := sha256Hex(filepath.Clean(state))
	return "bee-client-" + digest[:16]
}

// enrollClient writes the caller's public key into the owner's trusted
// directory under the pending enrollment directory the owner scans. The write
// is owner-only; a malformed key is never written.
func enrollClient(state, directory, node string, public ed25519.PublicKey) error {
	if len(public) != ed25519.PublicKeySize {
		return errors.New("client public key has an invalid length")
	}
	if !validTrustedName(node) {
		return errors.New("client node name is invalid")
	}
	trusted := ownerTrustedDirectory(state)
	if err := privatefile.EnsurePrivateDir(trusted); err != nil {
		return err
	}
	encoded := base64.RawStdEncoding.EncodeToString(public)
	return writeOwnerFile(filepath.Join(trusted, node+".pub"), []byte(encoded+"\n"))
}
