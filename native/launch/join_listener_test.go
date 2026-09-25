// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/wippyai/bee/native/hive/invite"
	"github.com/wippyai/bee/native/hive/meshtls"
	clusterapi "github.com/wippyai/runtime/api/cluster"
	"github.com/wippyai/runtime/cluster/internode"
)

type fakeMembership struct {
	local  clusterapi.NodeInfo
	others []clusterapi.NodeInfo
}

func (m fakeMembership) Nodes() []clusterapi.NodeInfo {
	return append([]clusterapi.NodeInfo{m.local}, m.others...)
}
func (m fakeMembership) LocalNode() clusterapi.NodeInfo { return m.local }
func (m fakeMembership) UpdateMeta(map[string]string)   {}

type fakeRedeemer struct {
	refusal error
	calls   []string
}

func (r *fakeRedeemer) Redeem(_ context.Context, id, secret, node string) error {
	r.calls = append(r.calls, id+"/"+secret+"/"+node)
	return r.refusal
}
func (r *fakeRedeemer) Close() {}

func joinAdmitter(t *testing.T, redeem redeemer) (*admitter, string) {
	t.Helper()
	state := t.TempDir()
	_, release, err := prepareOwner(state, true)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = release() })
	authority, err := ensureAuthority(ownerDirectory(state), time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return &admitter{state: state, node: ownerNodeName(state), authority: authority,
		membership: fakeMembership{local: clusterapi.NodeInfo{ID: ownerNodeName(state), Addr: "127.0.0.1:4100"}}, redeem: redeem}, state
}

func redeemRequest(t *testing.T) (invite.Request, ed25519.PublicKey) {
	t.Helper()
	public, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return invite.Request{Version: invite.Version, Invite: strings.Repeat("a", 32), Secret: strings.Repeat("b", 64),
		Node: "bee-owner-joiner", Addresses: []string{"127.0.0.1"}, Key: base64.RawStdEncoding.EncodeToString(public)}, public
}

// An admitted joiner is pinned as a Hive peer by the identity key it proved and
// receives the hive's secret, gossip seed, pool and its certified leaf.
func TestJoinListenerPinsAndCertifiesAnAdmittedJoiner(t *testing.T) {
	redeem := &fakeRedeemer{}
	a, state := joinAdmitter(t, redeem)
	identity, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	request, key := redeemRequest(t)
	admission, refused := a.admit(context.Background(), identity, request)
	if refused != nil {
		t.Fatal(refused)
	}
	if len(redeem.calls) != 1 || redeem.calls[0] != request.Invite+"/"+request.Secret+"/bee-owner-joiner" {
		t.Fatalf("supervisor redemption = %v", redeem.calls)
	}
	pinned, ok := resolveTrustedKey(ownerPeersDirectory(state), "bee-owner-joiner")
	if !ok || !pinned.Equal(identity) {
		t.Fatal("the joiner's proven identity key is not pinned")
	}
	secret, err := readMembershipSecret(state)
	if err != nil {
		t.Fatal(err)
	}
	if admission.Node != a.node || admission.Gossip != "127.0.0.1:4100" || admission.Secret != base64.StdEncoding.EncodeToString(secret) {
		t.Fatalf("admission = %+v", admission)
	}
	if err := meshtls.Verify([]byte(admission.Certificate), []byte(admission.Authorities), key, time.Now()); err != nil {
		t.Fatalf("certified leaf does not verify against the hive pool: %v", err)
	}
}

// A supervisor refusal reaches the joiner unchanged and pins nothing; a
// malformed request is refused before the supervisor is asked.
func TestJoinListenerRefusesWithoutPinning(t *testing.T) {
	redeem := &fakeRedeemer{refusal: &invite.Refused{Code: "CONFLICT", Message: "invite was already used"}}
	a, state := joinAdmitter(t, redeem)
	request, _ := redeemRequest(t)
	_, refused := a.admit(context.Background(), ed25519.PublicKey(make([]byte, ed25519.PublicKeySize)), request)
	if refused == nil || refused.Code != "CONFLICT" {
		t.Fatalf("refusal = %v", refused)
	}
	if _, err := os.Stat(filepath.Join(ownerPeersDirectory(state), "bee-owner-joiner.pub")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a refused joiner was pinned: %v", err)
	}
	for _, bad := range []invite.Request{
		func() invite.Request { r := request; r.Node = a.node; return r }(),
		func() invite.Request { r := request; r.Node = "bee owner"; return r }(),
		func() invite.Request { r := request; r.Key = "short"; return r }(),
		func() invite.Request { r := request; r.Addresses = []string{"0.0.0.0"}; return r }(),
	} {
		if _, refused := a.admit(context.Background(), nil, bad); refused == nil || refused.Code != "INVALID_ARGUMENT" {
			t.Fatalf("malformed request %+v = %v", bad, refused)
		}
	}
	if len(redeem.calls) != 1 {
		t.Fatalf("the supervisor was asked for malformed requests: %v", redeem.calls)
	}
}

// A peer that comes back at a new gossip address has its persisted seed
// rewritten, so the next boot seeds it where it now is. The rewrite is
// identity-pinned: a member whose gossiped key differs from the pin is ignored.
func TestPeerSeedsFollowAPeerThatMoves(t *testing.T) {
	state := t.TempDir()
	if _, release, err := prepareOwner(state, true); err != nil {
		t.Fatal(err)
	} else if err := release(); err != nil {
		t.Fatal(err)
	}
	peer, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if err := writeOwnerFile(filepath.Join(ownerPeersDirectory(state), "bee-owner-peer.pub"),
		[]byte(base64.RawStdEncoding.EncodeToString(peer)+"\n")); err != nil {
		t.Fatal(err)
	}
	membership := fakeMembership{local: clusterapi.NodeInfo{ID: ownerNodeName(state), Addr: "127.0.0.1:4100"},
		others: []clusterapi.NodeInfo{{ID: "bee-owner-peer", Addr: "127.0.0.1:4200",
			Meta: clusterapi.NodeMeta{internode.MetadataPublicKey: base64.RawStdEncoding.EncodeToString(peer)}}}}
	if err := recordAddresses(state, membership); err != nil {
		t.Fatal(err)
	}
	if _, seeds := prepareBindPort(t, state); seeds != "127.0.0.1:4200" {
		t.Fatalf("seeds = %q, want the peer's first address", seeds)
	}
	// The peer restarts with a new address; the same pinned key reports it.
	membership.others[0].Addr = "127.0.0.1:4300"
	if err := recordAddresses(state, membership); err != nil {
		t.Fatal(err)
	}
	if _, seeds := prepareBindPort(t, state); seeds != "127.0.0.1:4300" {
		t.Fatalf("seeds = %q, want the peer's new address", seeds)
	}
	// The node's own gossip port is remembered for the next boot.
	if port, _ := prepareBindPort(t, state); port != 4100 {
		t.Fatalf("remembered gossip port = %d, want 4100", port)
	}
}

// The republisher only tells the mesh about a changed address, and publishes
// the internode endpoint and dial direction together.
func TestRepublishAddressOnlyOnChange(t *testing.T) {
	state := t.TempDir()
	if _, release, err := prepareOwner(state, true); err != nil {
		t.Fatal(err)
	} else if err := release(); err != nil {
		t.Fatal(err)
	}
	published, err := resolveAdvertiseAddress(state)
	if err != nil {
		t.Fatal(err)
	}
	membership := &recordingMembership{}
	listener := &joinListenerComponent{state: state, published: published}
	if err := listener.republishAddress(membership); err != nil {
		t.Fatal(err)
	}
	if len(membership.meta) != 0 {
		t.Fatalf("an unchanged address was republished: %#v", membership.meta)
	}
	listener.published = netip.MustParseAddr("203.0.113.1")
	if err := listener.republishAddress(membership); err != nil {
		t.Fatal(err)
	}
	if membership.meta[internode.MetadataAdvertiseAddr] != published.String() ||
		membership.meta[internode.MetadataAdvertisePort] != "4100" {
		t.Fatalf("republished meta = %#v, want %s", membership.meta, published)
	}
	if listener.published != published {
		t.Fatalf("tracked address = %v, want %v", listener.published, published)
	}
}
