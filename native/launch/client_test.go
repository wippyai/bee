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
	"reflect"
	"strings"
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
		"x", rendezvous.Descriptor{}, nil, nil, nil)
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

func TestClientIntentGrammar(t *testing.T) {
	workspace, desktop := strings.Repeat("a", 32), strings.Repeat("b", 32)
	for _, case_ := range []struct {
		args []string
		want clientIntent
	}{
		{args: nil, want: clientIntent{}},
		{args: []string{"observe"}, want: clientIntent{observe: true, refusal: "No running Bee to observe; start bee first"}},
		{args: []string{"observe", workspace, desktop}, want: clientIntent{observe: true, workspace: workspace, desktop: desktop,
			refusal: "No running Bee to observe; start bee first"}},
		{args: []string{"attach", workspace, desktop}, want: clientIntent{workspace: workspace, desktop: desktop,
			refusal: "No running Bee for the selected desktop; start bee first"}},
		{args: []string{"client"}, want: clientIntent{refusal: "No running Bee for this project; run bee to start its node"}},
		{args: []string{"desktops"}, want: clientIntent{listing: true, refusal: "No running Bee to list; start bee first"}},
		{args: []string{"terminal", "bash", "-c", "printf %s ; $(exit 4)"}, want: clientIntent{command: []string{"terminal", "bash", "-c", "printf %s ; $(exit 4)"}}},
		{args: []string{"agent"}, want: clientIntent{command: []string{"agent"}}},
	} {
		got, err := parseClientIntent(case_.args)
		if err != nil {
			t.Fatalf("parseClientIntent(%q): %v", case_.args, err)
		}
		if !reflect.DeepEqual(got, case_.want) {
			t.Fatalf("parseClientIntent(%q) = %#v, want %#v", case_.args, got, case_.want)
		}
	}
	for _, bad := range [][]string{
		{"attach"},
		{"attach", workspace},
		{"observe", workspace},
		{"observe", "not-hex", desktop},
		{"client", workspace, strings.ToUpper(desktop)},
		{"desktops", "extra"},
	} {
		if _, err := parseClientIntent(bad); err == nil {
			t.Fatalf("parseClientIntent(%q) accepted", bad)
		}
	}
}

// Observing, attaching, selecting and listing act on a running Bee only: with
// no owner they refuse promptly, start nothing and write nothing.
func TestClientAttachOnlyIntentsNeverStartAnOwner(t *testing.T) {
	for _, args := range [][]string{{"observe"}, {"client"}, {"desktops"}} {
		state := filepath.Join(t.TempDir(), "state")
		owner := &fakeOwner{descriptor: fakeDescriptor(t)}
		intent, err := parseClientIntent(args)
		if err != nil {
			t.Fatal(err)
		}
		err = runClientEnsuresOwner(context.Background(), app.Launch{Op: app.OpRun, Command: desktopCommand, State: state, Dir: filepath.Dir(state), Explicit: true},
			owner.seams(filepath.Join(state, rendezvous.DirectoryName)), joinRequest{Intent: intent})
		if err == nil || err.Error() != intent.refusal {
			t.Fatalf("%q without an owner: %v", args, err)
		}
		if owner.started != 0 || owner.joined != 0 {
			t.Fatalf("%q started %d owners and joined %d times", args, owner.started, owner.joined)
		}
		if _, err := os.Stat(state); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("%q created the state directory: %v", args, err)
		}
	}
}

// Two clients of a free state each start an owner; the runtime state lock
// elects one and the other exits. The client whose contender lost joins the
// winner's publication instead of failing.
func TestClientJoinsTheWinnerWhenItsOwnerContenderLoses(t *testing.T) {
	state := t.TempDir()
	owner := &fakeOwner{descriptor: fakeDescriptor(t)}
	seams := owner.seams(filepath.Join(state, rendezvous.DirectoryName))
	lost := make(chan struct{})
	close(lost)
	won := false
	checks := 0
	seams.owned = func(string) (bool, error) {
		checks++
		// Free when this client looks; held by the winner once its own
		// contender has exited.
		return checks > 1, nil
	}
	seams.startOwner = func(context.Context, app.Launch) (<-chan struct{}, func() error, error) {
		return lost, func() error { won = true; return errors.New("exit status 1") }, nil
	}
	reads := 0
	seams.waitDescriptor = func(context.Context, string) (rendezvous.Descriptor, error) {
		reads++
		if !won {
			return rendezvous.Descriptor{}, os.ErrNotExist
		}
		return owner.descriptor, nil
	}
	if err := runClientEnsuresOwner(context.Background(), clientLaunch(state), seams, joinRequest{}); err != nil {
		t.Fatalf("client failed when its contender lost the owner election: %v", err)
	}
	if owner.joined != 1 || owner.lastJoin.Owner.Node != owner.descriptor.Node {
		t.Fatalf("joined %d times, owner %q", owner.joined, owner.lastJoin.Owner.Node)
	}
}

// A descriptor left by an owner that is gone is not this start's publication.
func TestClientWaitsForAFreshPublicationAfterStartingAnOwner(t *testing.T) {
	stale := fakeDescriptor(t)
	fresh := stale
	fresh.Transport = "127.0.0.1:9200"
	published := false
	read := func(context.Context, string) (rendezvous.Descriptor, error) {
		if published {
			return fresh, nil
		}
		published = true
		return stale, nil
	}
	got, err := waitDescriptorOrExit(context.Background(), read, "x", stale, nil, nil, nil)
	if err != nil || got != fresh {
		t.Fatalf("publication = %#v, %v; want the fresh descriptor", got, err)
	}
}
