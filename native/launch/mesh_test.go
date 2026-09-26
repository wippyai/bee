// SPDX-License-Identifier: MIT

package launch

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net"
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

func prepareCluster(t *testing.T, state string) (map[string]any, func() error) {
	t.Helper()
	config, release, err := prepareOwner(state, true)
	if err != nil {
		t.Fatal(err)
	}
	cluster := map[string]any{}
	section := config.Sub("cluster")
	for _, key := range []string{"membership.join_addrs", "membership.secret_file", "internode.tls.enabled", "internode.tls.cert_file", "internode.tls.key_file", "internode.tls.ca_file"} {
		value, _ := section.Get(key)
		cluster[key] = value
	}
	return cluster, release
}

// The owner's mesh always runs identity TLS: its leaf is certified by the
// node's own authority and its pool trusts that authority.
func TestPrepareOwnerSelectsMeshTLS(t *testing.T) {
	state := t.TempDir()
	cluster, release := prepareCluster(t, state)
	defer func() { _ = release() }()
	directory := ownerDirectory(state)
	if cluster["internode.tls.enabled"] != true || cluster["internode.tls.cert_file"] != filepath.Join(directory, meshtls.CredentialFile) ||
		cluster["internode.tls.key_file"] != cluster["internode.tls.cert_file"] || cluster["internode.tls.ca_file"] != filepath.Join(directory, meshtls.AuthoritiesFile) {
		t.Fatalf("cluster TLS = %v", cluster)
	}
	if cluster["membership.join_addrs"] != "" || cluster["membership.secret_file"] != filepath.Join(directory, membershipSecretName) {
		t.Fatalf("an unjoined node selected a hive: %v", cluster)
	}
	credential, err := os.ReadFile(filepath.Join(directory, meshtls.CredentialFile))
	if err != nil {
		t.Fatal(err)
	}
	pool, err := os.ReadFile(filepath.Join(directory, meshtls.AuthoritiesFile))
	if err != nil {
		t.Fatal(err)
	}
	authority, err := ensureAuthority(directory, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(pool, authority.Certificate()) {
		t.Fatal("the pool is not the node's own authority")
	}
	leaf, rest := splitCredential(t, credential)
	if err := meshtls.Verify(leaf, pool, rest, time.Now()); err != nil {
		t.Fatalf("owner leaf does not verify: %v", err)
	}
	for _, name := range []string{meshtls.AuthorityFile, meshtls.CredentialFile, meshtls.AuthoritiesFile} {
		info, err := os.Stat(filepath.Join(directory, name))
		if err != nil || info.Mode().Perm() != 0o600 {
			t.Fatalf("%s: %v %v", name, info, err)
		}
	}
}

// The owner picks its own advertise address: a Tailscale address when one is
// present, otherwise the first non-virtual LAN address, otherwise loopback.
// No environment variable participates, and the pick is persisted.
func TestOwnerPicksAndPersistsItsMeshAddress(t *testing.T) {
	state := t.TempDir()
	assigned, err := assignedInterfaceAddresses()
	if err != nil {
		t.Fatal(err)
	}
	tailnet, _ := tailscaleIdentity()
	want := pickAdvertiseAddress(assigned, tailnet)
	config, release, err := prepareOwner(state, true)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = release() }()
	section := config.Sub("cluster")
	for key := range map[string]bool{"membership.advertise_addr": true, "internode.advertise_addr": true} {
		if got := section.GetString(key, ""); got != want.String() {
			t.Errorf("%s = %q, want %q", key, got, want)
		}
	}
	for key, wantBind := range map[string]string{"membership.bind_addr": wantBindAddress(want), "internode.bind_addr": wantBindAddress(want)} {
		if got := section.GetString(key, ""); got != wantBind {
			t.Errorf("%s = %q, want %q", key, got, wantBind)
		}
	}
	recorded, ok, err := readAdvertise(ownerDirectory(state))
	if err != nil || !ok || recorded != want {
		t.Fatalf("persisted advertise = %v %v %v, want %v", recorded, ok, err, want)
	}
}

func wantBindAddress(address netip.Addr) string {
	if address.IsLoopback() {
		return address.String()
	}
	if address.Is4() {
		return "0.0.0.0"
	}
	return "::"
}

// splitCredential returns a credential's leaf and the public key of its private key.
func splitCredential(t *testing.T, credential []byte) ([]byte, ed25519.PublicKey) {
	t.Helper()
	index := bytes.Index(credential, []byte("-----BEGIN PRIVATE KEY-----"))
	if index < 0 {
		t.Fatal("credential has no key")
	}
	pair, err := tlsPair(credential)
	if err != nil {
		t.Fatal(err)
	}
	return credential[:index], pair
}

// One owner holds the state at a time; a hive join is refused while it runs.
func TestOwnerLockExcludesASecondOwner(t *testing.T) {
	state := t.TempDir()
	_, release := prepareCluster(t, state)
	if _, _, err := prepareOwner(state, true); !errors.Is(err, errOwnerRunning) {
		t.Fatalf("second owner preparation = %v", err)
	}
	if _, err := lockOwner(context.Background(), state); !errors.Is(err, errOwnerRunning) {
		t.Fatalf("join lock while the owner runs = %v", err)
	}
	if err := release(); err != nil {
		t.Fatal(err)
	}
	_, again := prepareCluster(t, state)
	if err := again(); err != nil {
		t.Fatal(err)
	}
}

// A joined node boots into its hive: the hive's secret, the hive node's
// gossip seed, the leaf the hive node certified and both authority pools.
func TestPrepareOwnerBootsAJoinedNodeIntoItsHive(t *testing.T) {
	state := t.TempDir()
	directory := ownerDirectory(state)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	document, err := meshtls.NewAuthority(now)
	if err != nil {
		t.Fatal(err)
	}
	hive, err := meshtls.DecodeAuthority(document, now)
	if err != nil {
		t.Fatal(err)
	}
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := hive.Issue(public, []netip.Addr{netip.MustParseAddr("127.0.0.1")}, now)
	if err != nil {
		t.Fatal(err)
	}
	credential, err := meshtls.Credential(leaf, private)
	if err != nil {
		t.Fatal(err)
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		t.Fatal(err)
	}
	record, err := json.Marshal(joinedRecord{Node: "bee-owner-hive", Gossip: "127.0.0.1:4100", Authorities: string(hive.Certificate())})
	if err != nil {
		t.Fatal(err)
	}
	for name, data := range map[string][]byte{
		joinedRecordName: record, joinedCredentialName: credential,
		joinedSecretName: []byte(base64.StdEncoding.EncodeToString(secret) + "\n"),
	} {
		if err := writeOwnerFile(filepath.Join(directory, name), data); err != nil {
			t.Fatal(err)
		}
	}
	cluster, release := prepareCluster(t, state)
	defer func() { _ = release() }()
	if cluster["membership.join_addrs"] != "127.0.0.1:4100" || cluster["membership.secret_file"] != filepath.Join(directory, joinedSecretName) {
		t.Fatalf("joined node cluster = %v", cluster)
	}
	active, err := os.ReadFile(filepath.Join(directory, meshtls.CredentialFile))
	if err != nil || !bytes.Equal(active, credential) {
		t.Fatalf("joined node does not use its certified leaf: %v", err)
	}
	pool, err := os.ReadFile(filepath.Join(directory, meshtls.AuthoritiesFile))
	if err != nil {
		t.Fatal(err)
	}
	roots, err := meshtls.Authorities(pool)
	if err != nil || len(roots) != 2 {
		t.Fatalf("joined pool = %d authorities, %v", len(roots), err)
	}
	if err := meshtls.Verify(leaf, pool, public, now); err != nil {
		t.Fatal(err)
	}
	loaded, err := readMembershipSecret(state)
	if err != nil || !bytes.Equal(loaded, secret) {
		t.Fatalf("enrollment seeds with another secret: %v", err)
	}
}

func tlsPair(credential []byte) (ed25519.PublicKey, error) {
	pair, err := tls.X509KeyPair(credential, credential)
	if err != nil {
		return nil, err
	}
	private, ok := pair.PrivateKey.(ed25519.PrivateKey)
	if !ok {
		return nil, errors.New("credential key is not Ed25519")
	}
	return private.Public().(ed25519.PublicKey), nil
}

// A running owner holds its state; a join waits for it to stop, because the
// node's mesh joins a hive when its owner boots.
func TestHiveJoinRefusesWhileTheOwnerRuns(t *testing.T) {
	state := t.TempDir()
	_, release := prepareCluster(t, state)
	defer func() { _ = release() }()
	line := invite.Invite{ID: strings.Repeat("a", 32), Secret: strings.Repeat("b", 64), Address: netip.MustParseAddrPort("127.0.0.1:1"),
		Node: "bee-owner-hive", Fingerprint: strings.Repeat("c", 64)}
	err := redeemInvite(context.Background(), state, line)
	if err == nil || !strings.Contains(err.Error(), "this Bee is running") {
		t.Fatalf("join while the owner runs = %v", err)
	}
}

// Leaving retires the peer's pin; leaving the joined hive also drops the
// joined record so the next owner boots its own mesh.
func TestHiveLeaveRetiresThePeerAndTheJoinedHive(t *testing.T) {
	state := t.TempDir()
	directory := ownerDirectory(state)
	if err := os.MkdirAll(ownerPeersDirectory(state), 0o700); err != nil {
		t.Fatal(err)
	}
	for _, node := range []string{"bee-owner-hive", "bee-owner-other"} {
		public, _, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		if err := writeOwnerFile(filepath.Join(ownerPeersDirectory(state), node+".pub"), []byte(base64.RawStdEncoding.EncodeToString(public)+"\n")); err != nil {
			t.Fatal(err)
		}
	}
	now := time.Now()
	document, err := meshtls.NewAuthority(now)
	if err != nil {
		t.Fatal(err)
	}
	hive, err := meshtls.DecodeAuthority(document, now)
	if err != nil {
		t.Fatal(err)
	}
	record, err := json.Marshal(joinedRecord{Node: "bee-owner-hive", Gossip: "127.0.0.1:4100", Authorities: string(hive.Certificate())})
	if err != nil {
		t.Fatal(err)
	}
	for name, data := range map[string][]byte{joinedRecordName: record, joinedSecretName: []byte("c2VjcmV0\n"), joinedCredentialName: []byte("leaf")} {
		if err := writeOwnerFile(filepath.Join(directory, name), data); err != nil {
			t.Fatal(err)
		}
	}
	var out bytes.Buffer
	if err := leaveHive(&out, state, "bee-owner-other"); err != nil {
		t.Fatal(err)
	}
	if _, ok := resolveTrustedKey(ownerPeersDirectory(state), "bee-owner-other"); ok {
		t.Fatal("a retired peer stayed pinned")
	}
	if _, joined, _ := readJoined(state); !joined {
		t.Fatal("leaving another peer dropped the joined hive")
	}
	if err := leaveHive(&out, state, "bee-owner-hive"); err != nil {
		t.Fatal(err)
	}
	if _, joined, err := readJoined(state); joined || err != nil {
		t.Fatalf("the joined hive survived leaving it: %v", err)
	}
	for _, name := range []string{joinedSecretName, joinedCredentialName} {
		if _, err := os.Stat(filepath.Join(directory, name)); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("%s survived leaving the hive: %v", name, err)
		}
	}
	if err := leaveHive(&out, state, "bee-owner-hive"); err == nil {
		t.Fatal("leaving a node that is no peer succeeded")
	}
	if out.String() != "Left bee-owner-other\nLeft bee-owner-hive\n" {
		t.Fatalf("output = %q", out.String())
	}
}

// A node that never started redeems an invite: it pins the hive node by the
// key the invite fingerprints and records the hive it boots into.
func TestRedeemInviteRecordsTheHiveOnAFreshNode(t *testing.T) {
	state := t.TempDir()
	_, hiveIdentity, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	document, err := meshtls.NewAuthority(now)
	if err != nil {
		t.Fatal(err)
	}
	hive, err := meshtls.DecodeAuthority(document, now)
	if err != nil {
		t.Fatal(err)
	}
	secret := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32))
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	served := make(chan error, 1)
	go func() {
		served <- invite.Serve(ctx, listener, hiveIdentity, func(_ context.Context, _ ed25519.PublicKey, request invite.Request) (invite.Admission, *invite.Refused) {
			key, err := base64.RawStdEncoding.DecodeString(request.Key)
			if err != nil {
				return invite.Admission{}, &invite.Refused{Code: "INVALID_ARGUMENT", Message: err.Error()}
			}
			leaf, err := hive.Issue(ed25519.PublicKey(key), nil, time.Now())
			if err != nil {
				return invite.Admission{}, &invite.Refused{Code: "INTERNAL", Message: err.Error()}
			}
			return invite.Admission{Node: "bee-owner-hive", Gossip: "127.0.0.1:4100", Secret: secret, Certificate: string(leaf), Authorities: string(hive.Certificate())}, nil
		})
	}()
	defer func() {
		cancel()
		if err := <-served; err != nil {
			t.Error(err)
		}
	}()
	line := invite.Invite{ID: strings.Repeat("a", 32), Secret: strings.Repeat("b", 64), Address: netip.MustParseAddrPort(listener.Addr().String()),
		Node: "bee-owner-hive", Fingerprint: invite.Fingerprint(hiveIdentity.Public().(ed25519.PublicKey))}
	if err := redeemInvite(context.Background(), state, line); err != nil {
		t.Fatal(err)
	}
	pinned, ok := resolveTrustedKey(ownerPeersDirectory(state), "bee-owner-hive")
	if !ok || !pinned.Equal(hiveIdentity.Public()) {
		t.Fatal("the hive node is not pinned by its fingerprinted key")
	}
	record, joined, err := readJoined(state)
	if err != nil || !joined || record.Node != "bee-owner-hive" || record.Gossip != "127.0.0.1:4100" {
		t.Fatalf("joined record = %+v %v %v", record, joined, err)
	}
	cluster, release := prepareCluster(t, state)
	defer func() { _ = release() }()
	if cluster["membership.join_addrs"] != "127.0.0.1:4100" {
		t.Fatalf("the joined node does not boot into its hive: %v", cluster)
	}
	if err := redeemInvite(context.Background(), state, line); err == nil || !strings.Contains(err.Error(), "running") {
		t.Fatalf("a second join while the owner runs = %v", err)
	}
}

// A node keeps its gossip port across boots and seeds every pinned peer's last
// gossip address beside its hive's, so either side of a hive can restart,
// cleanly or not, and find the other at a known address.
func TestPrepareOwnerKeepsItsGossipAddressAndSeedsKnownPeers(t *testing.T) {
	state := t.TempDir()
	cluster, release := prepareCluster(t, state)
	if err := release(); err != nil {
		t.Fatal(err)
	}
	if port, _ := prepareBindPort(t, state); port != 0 {
		t.Fatalf("a first boot binds port %d", port)
	}
	_ = cluster
	peer, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if err := writeOwnerFile(filepath.Join(ownerPeersDirectory(state), "bee-owner-peer.pub"), []byte(base64.RawStdEncoding.EncodeToString(peer)+"\n")); err != nil {
		t.Fatal(err)
	}
	membership := fakeMembership{local: clusterapi.NodeInfo{ID: ownerNodeName(state), Addr: "127.0.0.1:45123"}}
	membership.others = []clusterapi.NodeInfo{
		{ID: "bee-owner-peer", Addr: "127.0.0.1:45200", Meta: clusterapi.NodeMeta{internode.MetadataPublicKey: base64.RawStdEncoding.EncodeToString(peer)}},
		{ID: "bee-owner-stranger", Addr: "127.0.0.1:45300"},
	}
	if err := recordAddresses(state, membership); err != nil {
		t.Fatal(err)
	}
	port, seeds := prepareBindPort(t, state)
	if port != 45123 || seeds != "127.0.0.1:45200" {
		t.Fatalf("second boot binds %d and seeds %q", port, seeds)
	}
	// A member whose gossiped key differs from the pin is not recorded.
	membership.others[0].Meta = clusterapi.NodeMeta{internode.MetadataPublicKey: base64.RawStdEncoding.EncodeToString(make([]byte, ed25519.PublicKeySize))}
	membership.others[0].Addr = "127.0.0.1:45999"
	if err := recordAddresses(state, membership); err != nil {
		t.Fatal(err)
	}
	if _, seeds := prepareBindPort(t, state); seeds != "127.0.0.1:45200" {
		t.Fatalf("an unauthenticated member moved a peer's seed to %q", seeds)
	}
	var out bytes.Buffer
	if err := leaveHive(&out, state, "bee-owner-peer"); err != nil {
		t.Fatal(err)
	}
	if _, seeds := prepareBindPort(t, state); seeds != "" {
		t.Fatalf("a retired peer is still seeded: %q", seeds)
	}
}

func prepareBindPort(t *testing.T, state string) (int, string) {
	t.Helper()
	config, release, err := prepareOwner(state, true)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = release() }()
	section := config.Sub("cluster")
	value, _ := section.Get("membership.bind_port")
	port, _ := value.(int)
	return port, section.GetString("membership.join_addrs", "")
}
