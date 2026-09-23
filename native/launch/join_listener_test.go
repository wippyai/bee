// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/wippyai/bee/native/hive/invite"
	"github.com/wippyai/bee/native/hive/meshtls"
	clusterapi "github.com/wippyai/runtime/api/cluster"
)

type fakeMembership struct{ local clusterapi.NodeInfo }

func (m fakeMembership) Nodes() []clusterapi.NodeInfo   { return []clusterapi.NodeInfo{m.local} }
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
	_, release, err := prepareOwner(state)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = release() })
	authority, err := ensureAuthority(ownerDirectory(state), time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return &admitter{state: state, node: ownerNodeName(state), authority: authority,
		membership: fakeMembership{clusterapi.NodeInfo{ID: ownerNodeName(state), Addr: "127.0.0.1:4100"}}, redeem: redeem}, state
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
