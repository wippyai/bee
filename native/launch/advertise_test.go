// SPDX-License-Identifier: MIT

package launch

import (
	"net/netip"
	"os"
	"path/filepath"
	"testing"

	clusterapi "github.com/wippyai/runtime/api/cluster"
	"github.com/wippyai/runtime/cluster/internode"
)

// Advertise auto-pick prefers a Tailscale address, then the first
// non-virtual LAN address, then loopback when alone.
func TestPickAdvertisePrefersTailscaleThenLANThenLoopback(t *testing.T) {
	lan := netip.MustParseAddr("192.168.1.20")
	tail := netip.MustParseAddr("100.64.0.1")
	assigned := []interfaceAddress{
		{name: "eth0", address: lan},
		{name: "tailscale0", address: tail},
	}
	if got := pickAdvertiseAddress(assigned, []netip.Addr{tail}); got != tail {
		t.Fatalf("advertise = %v, want Tailscale %v", got, tail)
	}
	assigned = []interfaceAddress{
		{name: "docker0", address: netip.MustParseAddr("172.17.0.1")},
		{name: "eth0", address: lan},
	}
	if got := pickAdvertiseAddress(assigned, nil); got != lan {
		t.Fatalf("advertise = %v, want LAN %v", got, lan)
	}
	if got := pickAdvertiseAddress(nil, nil); !got.IsLoopback() {
		t.Fatalf("advertise when alone = %v, want loopback", got)
	}
}

// The picked address persists in hive/advertise and the next boot reads it
// back while this host still owns it, so a restart does not move the address
// the hive remembers.
func TestAdvertisePersistsAcrossBoots(t *testing.T) {
	state := t.TempDir()
	directory := ownerDirectory(state)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	lan := netip.MustParseAddr("192.168.1.21")
	assigned := []interfaceAddress{{name: "eth0", address: lan}}
	first, err := ensureAdvertiseAddress(directory, assigned, nil)
	if err != nil || first != lan {
		t.Fatalf("ensure = %v, %v; want %v", first, err, lan)
	}
	// A second boot sees the same interfaces and reads the stored address.
	second, err := ensureAdvertiseAddress(directory, assigned, nil)
	if err != nil || second != lan {
		t.Fatalf("reread = %v, %v; want persisted %v", second, err, lan)
	}
	data, err := os.ReadFile(filepath.Join(directory, advertiseFileName))
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != lan.String()+"\n" {
		t.Fatalf("advertise file = %q", data)
	}
	// A boot whose interface no longer carries that address repicks and
	// rewrites, so a DHCP lease change never advertises a stale address.
	moved := []interfaceAddress{{name: "eth0", address: netip.MustParseAddr("192.168.1.99")}}
	third, err := ensureAdvertiseAddress(directory, moved, nil)
	if err != nil || third != moved[0].address {
		t.Fatalf("after the address moved = %v, %v; want %v", third, err, moved[0].address)
	}
	// A Tailscale identity appearing between boots wins the pick.
	tail := netip.MustParseAddr("100.64.0.9")
	fourth, err := ensureAdvertiseAddress(directory, moved, []netip.Addr{tail})
	if err != nil || fourth != tail {
		t.Fatalf("after Tailscale came up = %v, %v; want %v", fourth, err, tail)
	}
}

// An observed join-path IP assigned locally replaces the persisted advertise
// address, so the node advertises exactly the address its hive authenticated.
// An unassigned one keeps the pick and records the node as NATed.
func TestObservedAddressReplacesAdvertiseWhenLocal(t *testing.T) {
	state := t.TempDir()
	directory := ownerDirectory(state)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	lan := netip.MustParseAddr("192.168.1.22")
	assigned := []interfaceAddress{{name: "eth0", address: lan}}
	if !isAssignedLocally(lan, assigned, nil) {
		t.Fatal("assigned LAN address is not local")
	}
	// The observed address is adopted when this host owns it.
	adopted, natted, err := applyObservedAddress(directory, lan.String(), assigned, nil)
	if err != nil || natted || adopted != lan {
		t.Fatalf("observed local address = %v %v %v, want %v", adopted, natted, err, lan)
	}
	if stored, ok, err := readAdvertise(directory); err != nil || !ok || stored != lan {
		t.Fatalf("persisted advertise = %v %v %v", stored, ok, err)
	}
	// An observed address this host does not own marks the node NATed and
	// leaves the pick in place.
	remote := netip.MustParseAddr("203.0.113.7")
	if isAssignedLocally(remote, assigned, nil) {
		t.Fatal("unassigned address reports local")
	}
	kept, natted, err := applyObservedAddress(directory, remote.String(), assigned, nil)
	if err != nil || !natted || kept != lan {
		t.Fatalf("observed remote address = %v %v %v, want %v NATed", kept, natted, err, lan)
	}
	recorded, ok, err := readNAT(directory)
	if err != nil || !ok || recorded != remote {
		t.Fatalf("recorded NAT address = %v %v %v, want %v", recorded, ok, err, remote)
	}
	if hint := meshDialHint(state); hint != dialOut {
		t.Fatalf("NATed node dial hint = %q, want %q", hint, dialOut)
	}
	// A later join that observes an address this host owns clears the mark.
	if _, natted, err := applyObservedAddress(directory, lan.String(), assigned, nil); err != nil || natted {
		t.Fatalf("clearing the NAT mark = %v %v", natted, err)
	}
	if _, ok, err := readNAT(directory); err != nil || ok {
		t.Fatalf("NAT mark survived = %v %v", ok, err)
	}
	if hint := meshDialHint(state); hint == dialOut {
		t.Fatal("an unnatted node still dials out")
	}
	// A malformed observation is refused rather than stored.
	for _, bad := range []string{"not-an-address", "0.0.0.0", "192.168.1.22%eth0"} {
		if _, _, err := applyObservedAddress(directory, bad, assigned, nil); err == nil {
			t.Fatalf("observed address %q was accepted", bad)
		}
	}
	// An absent observation (an older hive node) keeps the pick.
	kept, natted, err = applyObservedAddress(directory, "", assigned, nil)
	if err != nil || natted || kept != lan {
		t.Fatalf("absent observation = %v %v %v, want %v", kept, natted, err, lan)
	}
}

// No environment variable selects the mesh address, adds a join candidate or
// grants desktop access. Each legacy variable is inert even when set to a
// value that used to change behavior.
func TestMeshIgnoresLegacyAddressEnvironment(t *testing.T) {
	t.Setenv("BEE_MESH_ADDRESS", "203.0.113.254")
	t.Setenv("BEE_HIVE_ADDRESSES", "198.51.100.25")
	t.Setenv("BEE_DESKTOP_ALLOWED_PEERS", "bee-owner-peer")
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
	if got := section.GetString("membership.advertise_addr", ""); got != want.String() {
		t.Fatalf("advertise = %q, want the auto pick %q", got, want)
	}
	peers, err := selectedDesktopPeers(state)
	if err != nil {
		t.Fatal(err)
	}
	if len(peers) != 0 {
		t.Fatalf("desktop peers from env = %v, want no env grant", peers)
	}
	// The legacy hint no longer contributes an invite candidate.
	candidates, err := joinCandidates(netip.MustParseAddrPort("127.0.0.1:4200"))
	if err != nil {
		t.Fatal(err)
	}
	for _, candidate := range candidates {
		if candidate.Kind == "explicit" || candidate.Endpoint == "198.51.100.25:4200" {
			t.Fatalf("BEE_HIVE_ADDRESSES still added %+v", candidate)
		}
	}
}

// The dial hint is published only for a node the mesh cannot dial directly.
func TestMeshDialHintOnlyForANATedNode(t *testing.T) {
	state := t.TempDir()
	if err := os.MkdirAll(ownerDirectory(state), 0o700); err != nil {
		t.Fatal(err)
	}
	if hint := meshDialHint(state); hint == dialOut {
		t.Fatal("a directly reachable node dials out")
	}
	if err := os.WriteFile(filepath.Join(ownerDirectory(state), natFileName), []byte("203.0.113.7\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if hint := meshDialHint(state); hint != dialOut {
		t.Fatalf("NATed node dial hint = %q, want %q", hint, dialOut)
	}
}

// A NATed node advertises its dial hint through the membership metadata the
// runtime re-broadcasts. The pinned runtime has no boot-config key for
// membership metadata, so UpdateMeta is the only path, and its internode
// endpoint needs none: a member is dialed at its membership address.
func TestOwnerPublishesItsDialHintAndEndpoint(t *testing.T) {
	state := t.TempDir()
	if err := os.MkdirAll(ownerDirectory(state), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(ownerDirectory(state), natFileName), []byte("203.0.113.7\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if hint := meshDialHint(state); hint != dialOut {
		t.Fatalf("dial hint = %q, want %q", hint, dialOut)
	}
	membership := &recordingMembership{}
	publishMeshMeta(membership, dialOut)
	if len(membership.meta) != 1 || membership.meta[dialMetadataKey] != dialOut {
		t.Fatalf("published meta = %#v, want the dial direction alone", membership.meta)
	}
	// A directly reachable node publishes nothing: its endpoint follows the
	// membership address and it has no dial hint to add.
	direct := &recordingMembership{}
	publishMeshMeta(direct, "")
	if len(direct.meta) != 0 {
		t.Fatalf("a direct node published meta: %#v", direct.meta)
	}
}

// recordingMembership captures the metadata a node publishes.
type recordingMembership struct {
	meta clusterapi.NodeMeta
}

func (m *recordingMembership) Nodes() []clusterapi.NodeInfo { return nil }
func (m *recordingMembership) LocalNode() clusterapi.NodeInfo {
	return clusterapi.NodeInfo{ID: "bee-owner-local", Addr: "127.0.0.1:4100", Meta: clusterapi.NodeMeta{internode.MetadataPort: "4100"}}
}
func (m *recordingMembership) UpdateMeta(updates map[string]string) {
	if m.meta == nil {
		m.meta = clusterapi.NodeMeta{}
	}
	for key, value := range updates {
		m.meta[key] = value
	}
}

// The address a peer proved it can reach outranks the automatic pick, so a
// node whose preferred address (for example a Tailscale address) is not
// routable from one peer still advertises a path that peer reached.
func TestReachedAddressOutranksTheAutomaticPick(t *testing.T) {
	state := t.TempDir()
	directory := ownerDirectory(state)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	tail := netip.MustParseAddr("100.64.0.1")
	lan := netip.MustParseAddr("192.168.1.30")
	assigned := []interfaceAddress{{name: "eth0", address: lan}}
	tailnet := []netip.Addr{tail}
	// The automatic pick prefers Tailscale.
	if picked, err := ensureAdvertiseAddress(directory, assigned, tailnet); err != nil || picked != tail {
		t.Fatalf("automatic pick = %v, %v; want %v", picked, err, tail)
	}
	if effective, err := effectiveAdvertiseAddress(directory, assigned, tailnet); err != nil || effective != tail {
		t.Fatalf("effective before a peer reached us = %v, %v; want %v", effective, err, tail)
	}
	// A peer that reached the LAN address moves the advertisement there.
	if _, adopted, err := applyReachedAddress(directory, lan.String(), assigned, tailnet); err != nil || !adopted {
		t.Fatalf("applyReachedAddress = %v, %v; want adopted", adopted, err)
	}
	if effective, err := effectiveAdvertiseAddress(directory, assigned, tailnet); err != nil || effective != lan {
		t.Fatalf("effective after a peer reached us = %v, %v; want %v", effective, err, lan)
	}
	// A reached address this host no longer owns is ignored.
	if _, adopted, err := applyReachedAddress(directory, "203.0.113.7", assigned, tailnet); err != nil || adopted {
		t.Fatalf("an unowned reached address = %v, %v", adopted, err)
	}
	for _, bad := range []string{"not-an-address", "0.0.0.0", "192.168.1.30%eth0"} {
		if _, _, err := applyReachedAddress(directory, bad, assigned, tailnet); err == nil {
			t.Fatalf("reached address %q was accepted", bad)
		}
	}
	// An empty report and a loopback report change nothing.
	for _, value := range []string{"", "127.0.0.1"} {
		if _, adopted, err := applyReachedAddress(directory, value, assigned, tailnet); err != nil || adopted {
			t.Fatalf("reached address %q = %v, %v", value, adopted, err)
		}
	}
}
