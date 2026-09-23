// SPDX-License-Identifier: MIT

package launch

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/wippyai/bee/native/hive/rendezvous"
	app "github.com/wippyai/runtime/cmd/app"
)

func clientLaunch(state string) app.Launch {
	return app.Launch{Op: app.OpRun, Command: desktopCommand, State: state, Dir: state, Explicit: true}
}

// fakeOwner models a running owner: it answers Owned, publishes a descriptor on
// demand, and records the join it received.
type fakeOwner struct {
	lastJoin   joinRequest
	joined     int
	started    int
	descriptor rendezvous.Descriptor
}

func (f *fakeOwner) seams(directory string) clientSeams {
	return clientSeams{
		owned: func(string) (bool, error) { return f.started > 0, nil },
		startOwner: func(context.Context, app.Launch) (<-chan struct{}, func() error, error) {
			f.started++
			return nil, func() error { return nil }, nil
		},
		waitDescriptor: func(context.Context, string) (rendezvous.Descriptor, error) {
			if f.started == 0 {
				return rendezvous.Descriptor{}, os.ErrNotExist
			}
			return f.descriptor, nil
		},
		join: func(_ context.Context, join joinRequest) error {
			f.lastJoin = join
			f.joined++
			return nil
		},
		waitEnrolled: func(context.Context, string, string, ed25519.PublicKey) error { return nil },
		report:       io.Discard,
	}
}

func fakeDescriptor(t *testing.T) rendezvous.Descriptor {
	t.Helper()
	public, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	d := rendezvous.Descriptor{
		Version: 1, Execution: "0123456789abcdef0123456789abcdef", Node: "bee-owner-test",
		Gossip: "127.0.0.1:7946", Transport: "127.0.0.1:9100",
		PublicKey: base64.RawStdEncoding.EncodeToString(public),
	}
	return d
}

func TestClientSpawnsDetachedOwnerAndJoins(t *testing.T) {
	state := t.TempDir()
	owner := &fakeOwner{descriptor: fakeDescriptor(t)}
	seams := owner.seams(filepath.Join(state, rendezvous.DirectoryName))
	join := seams.join
	checked := false
	seams.join = func(ctx context.Context, request joinRequest) error {
		// While joined, the client's public key is pinned in the owner's
		// trusted directory, owner-only.
		trusted := ownerTrustedDirectory(state)
		data, err := os.ReadFile(filepath.Join(trusted, request.Node+".pub"))
		if err != nil {
			t.Fatalf("trusted key: %v", err)
		}
		decoded, err := base64.RawStdEncoding.DecodeString(string(data[:len(data)-1]))
		if err != nil || !request.Public.Equal(ed25519.PublicKey(decoded)) {
			t.Fatalf("trusted key does not match announced key")
		}
		info, err := os.Stat(filepath.Join(trusted, request.Node+".pub"))
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0o600 {
			t.Fatalf("trusted key mode = %o, want 0600", info.Mode().Perm())
		}
		checked = true
		return join(ctx, request)
	}
	err := runClientEnsuresOwner(context.Background(), clientLaunch(state), seams, joinRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if !checked {
		t.Fatal("client did not join")
	}
	if owner.started != 1 {
		t.Fatalf("owner started %d times, want 1", owner.started)
	}
	if owner.joined != 1 {
		t.Fatalf("joined %d times, want 1", owner.joined)
	}
	if owner.lastJoin.Owner.Node != "bee-owner-test" {
		t.Fatalf("join owner = %q", owner.lastJoin.Owner.Node)
	}
	if len(owner.lastJoin.Public) != ed25519.PublicKeySize {
		t.Fatalf("join public key length = %d", len(owner.lastJoin.Public))
	}
}

func TestClientReusesRunningOwnerWithoutSpawning(t *testing.T) {
	state := t.TempDir()
	owner := &fakeOwner{descriptor: fakeDescriptor(t)}
	owner.started = 1 // an owner is already running
	err := runClientEnsuresOwner(context.Background(), clientLaunch(state), owner.seams(filepath.Join(state, rendezvous.DirectoryName)), joinRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if owner.started != 1 {
		t.Fatalf("spawned another owner: %d", owner.started)
	}
	if owner.joined != 1 {
		t.Fatalf("joined %d times, want 1", owner.joined)
	}
}

func TestClientWaitsForEnrollmentBeforeJoining(t *testing.T) {
	state := t.TempDir()
	owner := &fakeOwner{descriptor: fakeDescriptor(t)}
	waited := false
	seams := owner.seams(filepath.Join(state, rendezvous.DirectoryName))
	seams.waitEnrolled = func(_ context.Context, gotState, node string, _ ed25519.PublicKey) error {
		waited = true
		if gotState != state || node == "" {
			t.Fatalf("waitEnrolled(%q, %q)", gotState, node)
		}
		return nil
	}
	if err := runClientEnsuresOwner(context.Background(), clientLaunch(state), seams, joinRequest{}); err != nil {
		t.Fatal(err)
	}
	if !waited {
		t.Fatal("client joined before its enrollment was registered")
	}
}

func TestClientFailsWhenOwnerExitsBeforePublishing(t *testing.T) {
	state := t.TempDir()
	done := make(chan struct{})
	close(done)
	seams := clientSeams{
		owned: func(string) (bool, error) { return false, nil },
		startOwner: func(context.Context, app.Launch) (<-chan struct{}, func() error, error) {
			return done, func() error { return errors.New("owner exited") }, nil
		},
		waitDescriptor: func(context.Context, string) (rendezvous.Descriptor, error) {
			return rendezvous.Descriptor{}, os.ErrNotExist
		},
		join:   func(context.Context, joinRequest) error { return errors.New("join must not run") },
		report: io.Discard,
	}
	err := runClientEnsuresOwner(context.Background(), clientLaunch(state), seams, joinRequest{})
	if err == nil {
		t.Fatal("client joined after the owner exited without publishing")
	}
}

func TestWaitDescriptorTimesOutBoundedly(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	_, err := waitDescriptorOrExit(ctx,
		func(context.Context, string) (rendezvous.Descriptor, error) {
			return rendezvous.Descriptor{}, os.ErrNotExist
		},
		"x", nil, nil)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("wait error = %v, want deadline exceeded", err)
	}
}

// The foreground names its route before the owner decides success: a free
// state starts the owner, an owned state connects to it.
func TestClientReportsItsRoute(t *testing.T) {
	for _, route := range []struct {
		name    string
		running bool
		want    string
	}{
		{name: "cold", running: false, want: "Starting Bee…\n"},
		{name: "warm", running: true, want: "Connecting to Hive…\n"},
	} {
		t.Run(route.name, func(t *testing.T) {
			state := t.TempDir()
			owner := &fakeOwner{descriptor: fakeDescriptor(t)}
			if route.running {
				owner.started = 1
			}
			var report bytes.Buffer
			seams := owner.seams(filepath.Join(state, rendezvous.DirectoryName))
			seams.report = &report
			if err := runClientEnsuresOwner(context.Background(), clientLaunch(state), seams, joinRequest{}); err != nil {
				t.Fatal(err)
			}
			if report.String() != route.want {
				t.Fatalf("route report = %q, want %q", report.String(), route.want)
			}
		})
	}
}

// Every launch is its own client node: concurrent clients of one state never
// share a mesh identity, and a returning client is never mistaken for the one
// that left. The trusted key exists exactly while the client is joined.
func TestClientIdentityIsPerLaunchAndRetiredOnExit(t *testing.T) {
	state := t.TempDir()
	owner := &fakeOwner{descriptor: fakeDescriptor(t)}
	seams := owner.seams(filepath.Join(state, rendezvous.DirectoryName))
	var nodes []string
	join := seams.join
	seams.join = func(ctx context.Context, request joinRequest) error {
		if request.Node != clientNodeName(request.Public) {
			t.Fatalf("join node %q does not name its key", request.Node)
		}
		if _, ok := resolveTrustedKey(ownerTrustedDirectory(state), request.Node); !ok {
			t.Fatal("joined without a trusted key")
		}
		nodes = append(nodes, request.Node)
		return join(ctx, request)
	}
	for range 2 {
		if err := runClientEnsuresOwner(context.Background(), clientLaunch(state), seams, joinRequest{}); err != nil {
			t.Fatal(err)
		}
	}
	if len(nodes) != 2 || nodes[0] == nodes[1] {
		t.Fatalf("client nodes = %v, want two distinct nodes", nodes)
	}
	entries, err := os.ReadDir(ownerTrustedDirectory(state))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		names := make([]string, 0, len(entries))
		for _, entry := range entries {
			names = append(names, entry.Name())
		}
		t.Fatalf("departed clients left %v", names)
	}
}
