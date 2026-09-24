// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/wippyai/bee/native/client/hive"
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
	owned func(state string) (bool, error)
	// startOwner starts a detached owner that publishes launchID as its launch
	// identity.
	startOwner     func(ctx context.Context, launch app.Launch, launchID string) (done <-chan struct{}, wait func() error, err error)
	waitDescriptor func(ctx context.Context, directory string) (rendezvous.Descriptor, error)
	join           func(ctx context.Context, join joinRequest) error
	// waitEnrolled blocks until the owner has registered the client's node in the
	// local enrollment, or the context ends.
	waitEnrolled func(ctx context.Context, state, node string, public ed25519.PublicKey) error
	// report receives the foreground route line.
	report io.Writer
	// released waits until no owner holds state.
	released func(ctx context.Context, state string) error
}

// clientIntent is what one ordinary invocation asks of the retained owner.
type clientIntent struct {
	observe   bool
	listing   bool
	workspace string
	desktop   string
	// command is an application name followed by its literal arguments; the
	// joined session submits it after admission, never the owner's startup.
	command []string
	// refusal is set when the intent acts on a running Bee only; it is the
	// answer when no owner holds the state, and no owner is started.
	refusal string
	// hive is a `bee hive` command. Its output is the command's own; the
	// route line is not printed.
	hive *hiveCommand
	// catalog is a `bee workspace` command against a running owner's
	// workspace catalog.
	catalog *workspaceCommand
	// stop asks the running owner to shut down; with alone set, only when no
	// other local client is enrolled with it.
	stop  bool
	alone bool
}

// parseClientIntent maps the invocation's arguments onto the client grammar:
// no arguments presents the project desktop; `observe`, `client` and `attach`
// join a running Bee, optionally pinned to one WORKSPACE DISPLAY pair;
// `desktops` lists a running Bee's displays; anything else names an
// application command to launch into the desktop. A word that cannot name an
// application command is refused here, before any state is selected.
func parseClientIntent(args []string) (clientIntent, error) {
	if len(args) == 0 {
		return clientIntent{}, nil
	}
	switch args[0] {
	case "hive":
		command, err := parseHive(args)
		if err != nil {
			return clientIntent{}, err
		}
		return clientIntent{hive: &command}, nil
	case "workspace":
		command, err := parseWorkspace(args)
		if err != nil {
			return clientIntent{}, err
		}
		return clientIntent{catalog: &command, refusal: "No running Bee to manage workspaces; start bee or bee daemon first"}, nil
	case "stop":
		if len(args) != 1 {
			return clientIntent{}, errors.New("bee stop takes no arguments")
		}
		return clientIntent{stop: true}, nil
	case "desktops":
		if len(args) != 1 {
			return clientIntent{}, errors.New("bee desktops takes no arguments")
		}
		return clientIntent{listing: true, refusal: "No running Bee to list; start bee first"}, nil
	case "observe", "client", "attach":
		intent := clientIntent{observe: args[0] == "observe"}
		switch {
		case len(args) == 3:
			for _, id := range args[1:] {
				decoded, err := hex.DecodeString(id)
				if err != nil || len(decoded) != 16 || hex.EncodeToString(decoded) != id {
					return clientIntent{}, errors.New("workspace and display must be 32 lowercase hexadecimal characters")
				}
			}
			intent.workspace, intent.desktop = args[1], args[2]
		case args[0] == "attach" || len(args) != 1:
			return clientIntent{}, errors.New("bee attach requires WORKSPACE DISPLAY; bee observe/client takes no application arguments or one WORKSPACE DISPLAY pair")
		}
		switch {
		case intent.observe:
			intent.refusal = "No running Bee to observe; start bee first"
		case intent.workspace != "":
			intent.refusal = "No running Bee for the selected desktop; start bee first"
		default:
			intent.refusal = "No running Bee for this project; run bee to start its node"
		}
		return intent, nil
	}
	if !(hive.DesktopCommand{Name: args[0]}).Valid() {
		return clientIntent{}, fmt.Errorf("unknown Bee command %q; run bee --help", args[0])
	}
	command := hive.DesktopCommand{Name: args[0], Arguments: append([]string{}, args[1:]...)}
	if !command.Valid() {
		return clientIntent{}, errors.New("invalid Bee command arguments")
	}
	return clientIntent{command: append([]string{}, args...)}, nil
}

// joinRequest is the client's authenticated join into the owner's mesh.
type joinRequest struct {
	Intent    clientIntent
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
func runClientEnsuresOwner(ctx context.Context, launch app.Launch, seams clientSeams, join joinRequest) (result error) {
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
	if join.Intent.refusal != "" && !owned {
		return errors.New(join.Intent.refusal)
	}
	if join.Intent.stop {
		if !owned {
			_, err := fmt.Fprintln(seams.report, "Bee is not running for this project")
			return err
		}
		if _, err := fmt.Fprintln(seams.report, "Stopping Bee…"); err != nil {
			return err
		}
	}
	// The route line describes routing only; the owner's publication and the
	// authenticated join still decide whether startup succeeds. A join to a
	// running Bee only names no route.
	if join.Intent.refusal == "" && join.Intent.hive == nil && !join.Intent.stop {
		route := "Starting Bee…"
		if owned {
			route = "Connecting to Hive…"
		}
		if _, err := fmt.Fprintln(seams.report, route); err != nil {
			return err
		}
	}
	// Several clients may start an owner at once; the state lock elects one.
	// This client's own start won only when the owner publishes the launch
	// identity it handed its child.
	started := false
	if !owned {
		previous, err := seams.waitDescriptor(ctx, directory)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		launchID, err := newLaunchIdentity()
		if err != nil {
			return err
		}
		done, wait, err := seams.startOwner(ctx, launch, launchID)
		if err != nil {
			return err
		}
		startup, cancel := context.WithTimeout(ctx, waitOwnerTimeout)
		defer cancel()
		held := func() (bool, error) { return seams.owned(launch.State) }
		published, err := waitDescriptorOrExit(startup, seams.waitDescriptor, directory, previous, done, wait, held)
		if err != nil {
			return fmt.Errorf("Bee owner startup: %w", err)
		}
		started = published.Launch == launchID
	}
	owner, err := seams.waitDescriptor(ctx, directory)
	if err != nil {
		return fmt.Errorf("Bee owner rendezvous: %w", err)
	}
	join.Directory = directory
	join.Owner = owner
	if join.Key == nil {
		public, private, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			return err
		}
		join.Public, join.Key = public, private
	}
	join.Node = clientNodeName(join.Public)
	release, err := enrollClient(ctx, launch.State, join.Node, join.Public)
	if err != nil {
		return err
	}
	defer func() { result = errors.Join(result, release()) }()
	// The owner registers the trusted key on its own bounded refresh, so wait
	// until the enrollment lists this node with this key before the mesh
	// handshake.
	if seams.waitEnrolled != nil {
		if err := seams.waitEnrolled(ctx, launch.State, join.Node, join.Public); err != nil {
			return err
		}
	}
	join.State = launch.State
	if err := seams.join(ctx, join); err != nil {
		// An owner this client started only for a command it refused retains no
		// desktop. The owner itself declines when another local client uses it.
		var refused *refusedCommand
		if started && errors.As(err, &refused) {
			stop := join
			stop.Intent = clientIntent{stop: true, alone: true}
			return errors.Join(err, seams.join(ctx, stop))
		}
		return err
	}
	if join.Intent.stop {
		if err := seams.released(ctx, launch.State); err != nil {
			return err
		}
		_, err := fmt.Fprintln(seams.report, "Bee stopped")
		return err
	}
	// A presenting client detaches from a retained owner; say it still runs
	// and how to end it.
	if join.Intent.hive != nil || join.Intent.catalog != nil || join.Intent.listing {
		return nil
	}
	running, err := seams.owned(launch.State)
	if err != nil || !running {
		return err
	}
	_, err = io.WriteString(seams.report, detachedLine)
	return err
}

// detachedLine follows a detached desktop client whose owner keeps running.
const detachedLine = "Bee is still running; bee stop ends it\n"

// waitDescriptorOrExit waits for a publication that differs from previous,
// the descriptor present before this client started an owner. The runtime
// state lock elects one owner among concurrent contenders: when the started
// child exits while owned reports the state held, the winner publishes and
// the wait continues; when the child exits and nothing holds the state, the
// start failed.
func waitDescriptorOrExit(ctx context.Context, read func(context.Context, string) (rendezvous.Descriptor, error),
	directory string, previous rendezvous.Descriptor, done <-chan struct{}, wait func() error, owned func() (bool, error)) (rendezvous.Descriptor, error) {
	tick := time.NewTicker(waitPollInterval)
	defer tick.Stop()
	finished := false
	for {
		if err := ctx.Err(); err != nil {
			return rendezvous.Descriptor{}, err
		}
		if descriptor, err := read(ctx, directory); err == nil && descriptor != previous {
			return descriptor, nil
		} else if err != nil && !errors.Is(err, os.ErrNotExist) {
			return rendezvous.Descriptor{}, err
		}
		if done != nil && !finished {
			select {
			case <-done:
				finished = true
				var childErr error
				if wait != nil {
					childErr = wait()
				}
				held := false
				if owned != nil {
					var err error
					if held, err = owned(); err != nil {
						return rendezvous.Descriptor{}, errors.Join(childErr, err)
					}
				}
				if !held {
					if childErr != nil {
						return rendezvous.Descriptor{}, childErr
					}
					return rendezvous.Descriptor{}, errors.New("Bee owner exited before publishing its rendezvous")
				}
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

// clientNodeName names the client node after its per-launch public key, so
// concurrent clients of one state never share a mesh identity and a returning
// client is never taken for the one that left.
func clientNodeName(public ed25519.PublicKey) string {
	return "bee-client-" + sha256Hex(string(public))[:16]
}

// enrollClient holds the node's liveness lock and writes the caller's public
// key into the owner's trusted directory. The owner retires a key whose lock
// is free, so an abruptly ended client leaves nothing enrolled. The returned
// release retires the key on a clean exit.
func enrollClient(ctx context.Context, state, node string, public ed25519.PublicKey) (func() error, error) {
	if len(public) != ed25519.PublicKeySize {
		return nil, errors.New("client public key has an invalid length")
	}
	if !validTrustedName(node) {
		return nil, errors.New("client node name is invalid")
	}
	trusted := ownerTrustedDirectory(state)
	if err := privatefile.EnsurePrivateDir(trusted); err != nil {
		return nil, err
	}
	unlock, err := privatefile.TryLock(ctx, trusted, clientLockName(node))
	if err != nil {
		return nil, err
	}
	key := filepath.Join(trusted, node+".pub")
	encoded := base64.RawStdEncoding.EncodeToString(public)
	if err := writeOwnerFile(key, []byte(encoded+"\n")); err != nil {
		return nil, errors.Join(err, unlock(), os.Remove(filepath.Join(trusted, clientLockName(node))))
	}
	return func() error {
		removed := os.Remove(key)
		return errors.Join(removed, unlock(), os.Remove(filepath.Join(trusted, clientLockName(node))))
	}, nil
}

// refusedCommand is the owner's refusal of the application command a client
// asked it to launch.
type refusedCommand struct{ cause error }

func (e *refusedCommand) Error() string { return e.cause.Error() }
func (e *refusedCommand) Unwrap() error { return e.cause }

// clientLockName is the liveness lock a joined client holds for its node.
func clientLockName(node string) string { return node + ".lock" }
