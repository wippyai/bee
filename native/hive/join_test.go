// SPDX-License-Identifier: MIT

package hive

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"net"
	"net/netip"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	clusterapi "github.com/wippyai/runtime/api/cluster"
	"github.com/wippyai/runtime/cluster/internode"

	"github.com/wippyai/bee/native/hive/invite"
)

// lockedBuffer is a writer the invite goroutine and the test share.
type lockedBuffer struct {
	mu   sync.Mutex
	data bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.data.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.data.String()
}

func hasRoutableInterface(t *testing.T) {
	t.Helper()
	assigned, err := assignedInterfaceAddresses()
	require.NoError(t, err)
	if len(assigned) == 0 {
		t.Skip("no routable interface")
	}
}

func TestInviteAndJoinMergeTheHivesOfTwoMachines(t *testing.T) {
	hasRoutableInterface(t)
	inviter, joiner := t.TempDir(), t.TempDir()
	out, notes := &lockedBuffer{}, &lockedBuffer{}
	done := make(chan error, 1)
	go func() { done <- Invite(context.Background(), inviter, out, notes) }()
	require.Eventually(t, func() bool { return strings.Contains(out.String(), "\n") }, 5*time.Second, 10*time.Millisecond)
	token := strings.TrimSpace(out.String())
	line, err := invite.Parse(token)
	require.NoError(t, err)

	var joined bytes.Buffer
	require.NoError(t, Join(context.Background(), joiner, token, &joined))
	require.NoError(t, <-done)

	left, err := ReadHive(inviter)
	require.NoError(t, err)
	right, err := ReadHive(joiner)
	require.NoError(t, err)
	require.Equal(t, left.Secret, right.Secret, "the joiner adopts the hive secret")
	require.NotEqual(t, left.Machine, right.Machine)
	require.Equal(t, line.Node, left.Machine)
	require.NotEmpty(t, left.Advertise)
	require.NotEmpty(t, right.Advertise)
	require.Contains(t, right.Seeds, net.JoinHostPort(left.Advertise, strconv.Itoa(left.Port)), "the joiner dials the inviter's gossip port")
	require.Contains(t, left.Seeds, net.JoinHostPort(right.Advertise, strconv.Itoa(right.Port)), "the inviter dials the joiner's gossip port")
	require.Contains(t, joined.String(), "Joined the hive of machine "+left.Machine)
	require.Contains(t, notes.String(), "joined the hive")
	require.NotContains(t, joined.String(), "could not reach", "the inviter reached the joiner back")
}

func TestAnInviteRedeemsOnceWithItsSecret(t *testing.T) {
	dir := t.TempDir()
	hive, err := Ensure(dir)
	require.NoError(t, err)
	_, identity, err := ed25519.GenerateKey(rand.Reader)
	require.NoError(t, err)
	session := &inviteSession{dir: dir, id: strings.Repeat("a", 32), identity: identity, expires: time.Now().Add(time.Minute),
		notes: &lockedBuffer{}, finished: func() {}}
	session.digest = sha256.Sum256([]byte(strings.Repeat("b", 64)))
	peer := identity.Public().(ed25519.PublicKey)
	request := invite.Request{Invite: strings.Repeat("a", 32), Secret: strings.Repeat("b", 64), Node: "other-machine",
		Addresses: []string{}, ProbePort: 1, Port: 40000, Observed: "192.0.2.7", Local: "192.0.2.1"}

	wrong := request
	wrong.Secret = strings.Repeat("c", 64)
	require.IsType(t, invite.Rejected{}, session.handle(context.Background(), peer, wrong))
	self := request
	self.Node = hive.Machine
	require.IsType(t, invite.Rejected{}, session.handle(context.Background(), peer, self), "a machine cannot join its own hive")

	accepted, ok := session.handle(context.Background(), peer, request).(invite.Accepted)
	require.True(t, ok)
	require.Equal(t, hive.Machine, accepted.Admission.Node)
	require.Equal(t, hive.Secret, accepted.Admission.Secret)
	require.Equal(t, []string{net.JoinHostPort("192.0.2.1", strconv.Itoa(hive.Port))}, accepted.Admission.Seeds)

	again, ok := session.handle(context.Background(), peer, request).(invite.Rejected)
	require.True(t, ok)
	require.Equal(t, "CONFLICT", again.Refusal.Code)

	stored, err := ReadHive(dir)
	require.NoError(t, err)
	require.Equal(t, "192.0.2.1", stored.Advertise)
	require.Empty(t, stored.Seeds, "an unreachable joiner is not a seed")
}

func TestAnExpiredInviteIsRefused(t *testing.T) {
	dir := t.TempDir()
	_, err := Ensure(dir)
	require.NoError(t, err)
	session := &inviteSession{dir: dir, id: strings.Repeat("a", 32), expires: time.Now().Add(-time.Second), notes: &lockedBuffer{}, finished: func() {}}
	session.digest = sha256.Sum256([]byte(strings.Repeat("b", 64)))
	refused, ok := session.handle(context.Background(), nil, invite.Request{Invite: strings.Repeat("a", 32), Secret: strings.Repeat("b", 64)}).(invite.Rejected)
	require.True(t, ok)
	require.Equal(t, "EXPIRED", refused.Refusal.Code)
}

func TestEnsureCompletesAnOlderHiveRecord(t *testing.T) {
	dir := t.TempDir()
	require.NoError(t, WriteHive(dir, Hive{Secret: "c2VjcmV0"}))
	hive, err := Ensure(dir)
	require.NoError(t, err)
	require.Equal(t, "c2VjcmV0", hive.Secret)
	require.Len(t, hive.Machine, 16)
	require.GreaterOrEqual(t, hive.Port, 30000)
	again, err := Ensure(dir)
	require.NoError(t, err)
	require.Equal(t, hive.Machine, again.Machine)
	require.Equal(t, hive.Port, again.Port)
}

func TestNodesListenOnLoopbackUntilTheHiveSpansMachines(t *testing.T) {
	dir := isolatedConfig(t)
	local := Hive{Secret: base64.StdEncoding.EncodeToString(make([]byte, 32)), Machine: "m", Port: 31000}
	config, _, err := Prepare(dir, t.TempDir(), local, &Members{})
	require.NoError(t, err)
	cluster := config.Sub("cluster")
	require.Equal(t, "127.0.0.1", cluster.GetString("membership.bind_addr", ""))
	require.Equal(t, "127.0.0.1", cluster.GetString("internode.bind_addr", ""))
	require.Equal(t, "", cluster.GetString("membership.advertise_addr", ""))

	shared := local
	shared.Advertise = "100.70.0.69"
	shared.Seeds = []string{"100.70.10.28:31001"}
	config, _, err = Prepare(dir, t.TempDir(), shared, &Members{})
	require.NoError(t, err)
	cluster = config.Sub("cluster")
	require.Equal(t, "0.0.0.0", cluster.GetString("membership.bind_addr", ""))
	require.Equal(t, "0.0.0.0", cluster.GetString("internode.bind_addr", ""))
	require.Equal(t, "100.70.0.69", cluster.GetString("membership.advertise_addr", ""))
	require.Contains(t, cluster.GetString("membership.join_addrs", ""), "100.70.10.28:31001")
}

func TestTheFirstNodeOfAMachineHoldsItsGossipPort(t *testing.T) {
	held, err := net.Listen("tcp", "0.0.0.0:0")
	require.NoError(t, err)
	defer held.Close()
	busy := held.Addr().(*net.TCPAddr).Port
	require.Zero(t, freeGossipPort(busy), "a taken port leaves the choice to the runtime")
	free, err := net.Listen("tcp", "0.0.0.0:0")
	require.NoError(t, err)
	port := free.Addr().(*net.TCPAddr).Port
	require.NoError(t, free.Close())
	require.Equal(t, port, freeGossipPort(port))
}

type gossip struct{ nodes []clusterapi.NodeInfo }

func (g gossip) Nodes() []clusterapi.NodeInfo   { return g.nodes }
func (g gossip) LocalNode() clusterapi.NodeInfo { return clusterapi.NodeInfo{} }
func (g gossip) UpdateMeta(map[string]string)   {}
func (g gossip) Link(clusterapi.NodeID) (clusterapi.Link, bool) {
	return clusterapi.Link{}, false
}

func TestNodesOfOtherMachinesAreTrustedUnderTheirAdvertisedKeyInASharedHive(t *testing.T) {
	dir := isolatedConfig(t)
	public, _, err := ed25519.GenerateKey(rand.Reader)
	require.NoError(t, err)
	advertised := base64.RawStdEncoding.EncodeToString(public)
	members := &Members{}
	members.bind(gossip{nodes: []clusterapi.NodeInfo{
		{ID: "bee-remote", Meta: clusterapi.NodeMeta{internode.MetadataPublicKey: advertised}},
		{ID: "intruder", Meta: clusterapi.NodeMeta{internode.MetadataPublicKey: advertised}},
	}})
	source := func(hive Hive) clusterapi.PeerKeySource {
		config, _, err := Prepare(dir, t.TempDir(), hive, members)
		require.NoError(t, err)
		raw, ok := config.Sub("cluster").Get("internode.peer_key_source")
		require.True(t, ok)
		return raw.(clusterapi.PeerKeySource)
	}
	secret := base64.StdEncoding.EncodeToString(make([]byte, 32))

	key, ok := source(Hive{Secret: secret, Advertise: "192.0.2.1"})("bee-remote")
	require.True(t, ok)
	require.True(t, key.Equal(public))
	_, ok = source(Hive{Secret: secret, Advertise: "192.0.2.1"})("intruder")
	require.False(t, ok, "only hive node names are trusted")
	_, ok = source(Hive{Secret: secret, Advertise: "192.0.2.1"})("bee-unseen")
	require.False(t, ok, "a node absent from gossip is not trusted")
	_, ok = source(Hive{Secret: secret})("bee-remote")
	require.False(t, ok, "a machine outside a shared hive trusts published keys only")

	other, _, err := ed25519.GenerateKey(rand.Reader)
	require.NoError(t, err)
	require.NoError(t, writeFile(filepath.Join(dir, nodesDir, "bee-remote"+keySuffix), []byte(base64.StdEncoding.EncodeToString(other))))
	key, ok = source(Hive{Secret: secret, Advertise: "192.0.2.1"})("bee-remote")
	require.True(t, ok)
	require.True(t, key.Equal(other), "a locally published key wins over the advertised one")
}

func TestSelectedCandidatesPreferTheTailnetThenTheLAN(t *testing.T) {
	assigned := []interfaceAddress{
		{name: "docker0", address: netip.MustParseAddr("172.17.0.1")},
		{name: "eth0", address: netip.MustParseAddr("192.168.1.4")},
		{name: "tailscale0", address: netip.MustParseAddr("100.70.0.69")},
	}
	candidates := selectJoinCandidates(47931, assigned, []netip.Addr{netip.MustParseAddr("100.70.0.69")}, "box.tail1234.ts.net")
	var endpoints []string
	for _, candidate := range candidates {
		require.True(t, candidate.Valid(), candidate.Endpoint)
		endpoints = append(endpoints, candidate.Endpoint)
	}
	require.Equal(t, []string{"100.70.0.69:47931", "box.tail1234.ts.net:47931", "192.168.1.4:47931", "172.17.0.1:47931"}, endpoints)
	require.Equal(t, "vm", candidates[3].Scope)
}

func TestJoinFailureNamesTheEndpointsAndTheWSLRemedy(t *testing.T) {
	line := invite.Invite{Address: netip.MustParseAddrPort("172.30.1.2:47931"),
		Candidates: []invite.Candidate{{Kind: "interface", Scope: "lan", Endpoint: "192.168.1.4:47931"}}}
	advice := joinFailureAdvice(line)
	require.Contains(t, advice, "172.30.1.2:47931")
	require.Contains(t, advice, "192.168.1.4:47931")
	require.Contains(t, advice, "networkingMode=mirrored")
	require.Contains(t, advice, "wsl --shutdown")
	require.NotContains(t, joinFailureAdvice(invite.Invite{Address: netip.MustParseAddrPort("192.168.1.4:47931")}), "networkingMode")
}

func TestJoinRefusesAMalformedToken(t *testing.T) {
	err := Join(context.Background(), t.TempDir(), "not-a-token", &bytes.Buffer{})
	require.ErrorContains(t, err, "invalid Bee Hive invite")
}
