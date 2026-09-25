// SPDX-License-Identifier: MIT

package rendezvous

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/wippyai/runtime/api/boot"
	"github.com/wippyai/runtime/api/cluster"
	ctxapi "github.com/wippyai/runtime/api/context"
	"github.com/wippyai/runtime/cluster/internode"
)

func sample() Descriptor {
	return Descriptor{Version: 1, Execution: strings.Repeat("a", 32), Node: "forge",
		Gossip: "100.70.10.28:40001", Transport: "100.70.10.28:40002",
		PublicKey: base64.RawStdEncoding.EncodeToString(make([]byte, 32))}
}

func TestStrictDescriptorBoundary(t *testing.T) {
	d := sample()
	d.ClientRevision = ClientRevision
	data, _ := json.Marshal(d)
	got, err := Decode(data)
	if err != nil || got != d {
		t.Fatalf("roundtrip: %v %v", got, err)
	}
	cases := []string{
		strings.Replace(string(data), `"version":1`, `"version":2`, 1),
		strings.Replace(string(data), `"version":1`, `"version":1,"version":1`, 1),
		strings.Replace(string(data), `"version":1`, `"Version":1`, 1),
		strings.Replace(string(data), `"version":1`, `"version":null`, 1),
		strings.Replace(string(data), `"version":1,`, ``, 1),
		strings.Replace(string(data), `"version":1`, `"version":1,"unknown":true`, 1),
		string(data) + `{}`, strings.Repeat(" ", MaxBytes+1),
		strings.Replace(string(data), "100.70.10.28:40002", "0.0.0.0:40002", 1),
		strings.Replace(string(data), "100.70.10.28:40002", "100.70.10.28:0", 1),
	}
	for i, value := range cases {
		if _, err := Decode([]byte(value)); !errors.Is(err, ErrDescriptor) {
			t.Errorf("case %d accepted: %v", i, err)
		}
	}
}

func TestReadDoesNotCreateStateAndPublishIsAtomic(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "discovery")
	store, err := New(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Read(context.Background()); !errors.Is(err, os.ErrNotExist) {
		t.Fatal(err)
	}
	if _, err := os.Stat(dir); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("read created state")
	}
	d := sample()
	if err := store.Publish(context.Background(), d); err != nil {
		t.Fatal(err)
	}
	alternate := d
	alternate.Execution = strings.Repeat("b", 32)
	alternate.Node = "replacement"
	alternate.Gossip = "127.0.0.1:41001"
	alternate.Transport = "127.0.0.1:41002"
	var workers sync.WaitGroup
	for i := range 4 {
		workers.Go(func() {
			for range 10 {
				if i%2 == 0 {
					next := d
					if i == 2 {
						next = alternate
					}
					if err := store.Publish(context.Background(), next); err != nil {
						t.Error(err)
						return
					}
				} else if got, err := store.Read(context.Background()); err != nil || got != d && got != alternate {
					t.Errorf("partial descriptor: %v %v", got, err)
					return
				}
			}
		})
	}
	workers.Wait()
	before, err := os.ReadFile(filepath.Join(dir, FileName))
	if err != nil {
		t.Fatal(err)
	}
	invalid := d
	invalid.Version = 9
	if err := store.Publish(context.Background(), invalid); !errors.Is(err, ErrDescriptor) {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := store.Publish(ctx, d); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	after, err := os.ReadFile(filepath.Join(dir, FileName))
	if err != nil || string(after) != string(before) {
		t.Fatal("failed publish changed descriptor")
	}
	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) != 2 {
		t.Fatalf("unexpected state: %v %v", entries, err)
	}
}

type membership struct{ node cluster.NodeInfo }

func (m membership) LocalNode() cluster.NodeInfo  { return m.node }
func (m membership) Nodes() []cluster.NodeInfo    { return []cluster.NodeInfo{m.node} }
func (m membership) UpdateMeta(map[string]string) {}

func TestPublisherRequiresStartedMembershipAndPreservesDescriptor(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "discovery")
	d := sample()
	d.ClientRevision = ClientRevision
	component, err := Publisher(dir, d.Execution, "")
	if err != nil {
		t.Fatal(err)
	}
	start := component.(boot.Starter)
	ctx := ctxapi.WithAppContext(context.Background(), ctxapi.NewAppContext())
	if err := start.Start(ctx); err == nil {
		t.Fatal("published without cluster")
	}
	m := &membership{node: cluster.NodeInfo{ID: d.Node, Addr: d.Gossip, Meta: cluster.NodeMeta{
		internode.MetadataPublicKey: d.PublicKey,
	}}}
	ctx = cluster.WithMembership(ctx, m)
	if err := start.Start(ctx); err == nil {
		t.Fatal("published before retained port")
	}
	m.node.Meta[internode.MetadataPort] = "40002"
	if err := start.Start(ctx); err != nil {
		t.Fatal(err)
	}
	store, _ := New(dir)
	got, err := store.Read(ctx)
	if err != nil || got != d {
		t.Fatalf("published: %v %v", got, err)
	}
	if stop, ok := component.(boot.Stopper); ok {
		if err := stop.Stop(ctx); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := store.Read(ctx); err != nil {
		t.Fatal("shutdown removed discovery hint", err)
	}
	m.node.Meta[internode.MetadataAdvertiseAddr] = "192.168.1.10"
	m.node.Meta[internode.MetadataAdvertisePort] = "45000"
	external, err := Capture(m.node, d.Execution)
	if err != nil || external.Transport != "192.168.1.10:45000" {
		t.Fatalf("override: %v %v", external, err)
	}
}

func TestLocalAliasMatchesExternallyAdvertisedOwner(t *testing.T) {
	publicKey := base64.RawStdEncoding.EncodeToString(make([]byte, 32))
	node := cluster.NodeInfo{ID: "joined-node", Addr: "192.0.2.20:4400", Meta: cluster.NodeMeta{
		internode.MetadataPort:          "4401",
		internode.MetadataPublicKey:     publicKey,
		internode.MetadataAdvertiseAddr: "192.0.2.20",
		internode.MetadataAdvertisePort: "4501",
	}}
	descriptor, err := CaptureLocal(node, strings.Repeat("c", 32), netip.MustParseAddr("127.0.0.1"), netip.MustParseAddr("::1"))
	if err != nil {
		t.Fatal(err)
	}
	if descriptor.Gossip != "127.0.0.1:4400" || descriptor.Transport != "[::1]:4401" || !descriptor.MatchesNode(node) {
		t.Fatalf("local alias did not match live owner: %#v", descriptor)
	}
	changed := node
	changed.Meta = cluster.NodeMeta{}
	for key, value := range node.Meta {
		changed.Meta[key] = value
	}
	changed.Meta[internode.MetadataPort] = "4402"
	if descriptor.MatchesNode(changed) {
		t.Fatal("local alias accepted a different listener")
	}
}

func TestDescriptorSupervisorAddress(t *testing.T) {
	base := sample()
	if err := base.validate(); err != nil {
		t.Fatalf("descriptor without a supervisor address: %v", err)
	}
	// The published supervisor address must name this node and the supervisor
	// host; anything else is refused so a descriptor cannot redirect a client.
	base.Supervisor = "{forge@bee.hive:supervisor_host|0x1}"
	if err := base.validate(); err != nil {
		t.Fatalf("valid supervisor address refused: %v", err)
	}
	for _, bad := range []string{
		"{other@bee.hive:supervisor_host|0x1}",
		"{forge@bee:workers|0x1}",
		"{forge@bee.hive:supervisor_host|}",
		"not-a-pid",
	} {
		invalid := base
		invalid.Supervisor = bad
		if err := invalid.validate(); err == nil {
			t.Fatalf("supervisor address %q was accepted", bad)
		}
	}
}

// The owner publishes its supervisor address after startup; every later read
// must decode it, and a null or repeated address stays refused.
func TestDescriptorDecodesPublishedSupervisorAddress(t *testing.T) {
	published := sample()
	published.Supervisor = "{forge@bee.hive:supervisor_host|0x1}"
	data, err := json.Marshal(published)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := Decode(data)
	if err != nil {
		t.Fatalf("published supervisor address refused on read: %v", err)
	}
	if decoded != published {
		t.Fatalf("decoded descriptor = %#v, want %#v", decoded, published)
	}
	withoutField := bytes.Replace(data, []byte(`,"supervisor":"{forge@bee.hive:supervisor_host|0x1}"`), nil, 1)
	if _, err := Decode(withoutField); err != nil {
		t.Fatalf("descriptor without a supervisor address refused: %v", err)
	}
	for _, bad := range [][]byte{
		bytes.Replace(data, []byte(`"{forge@bee.hive:supervisor_host|0x1}"`), []byte(`null`), 1),
		append(data[:len(data)-1:len(data)-1], []byte(`,"supervisor":"{forge@bee.hive:supervisor_host|0x2}"}`)...),
		bytes.Replace(data, []byte(`"{forge@bee.hive:supervisor_host|0x1}"`), []byte(`"{other@bee.hive:supervisor_host|0x1}"`), 1),
	} {
		if _, err := Decode(bad); err == nil {
			t.Fatalf("descriptor %s was accepted", bad)
		}
	}
}

// The live membership record authenticates the owner's endpoint; the published
// supervisor address is a hint the membership never carries.
func TestEndpointMatchesTheLiveMembershipCapture(t *testing.T) {
	published := sample()
	published.Supervisor = "{forge@bee.hive:supervisor_host|0x1}"
	node := cluster.NodeInfo{ID: published.Node, Addr: published.Gossip, Meta: cluster.NodeMeta{
		internode.MetadataPublicKey: published.PublicKey,
		internode.MetadataPort:      "40002",
	}}
	captured, err := Capture(node, published.Execution)
	if err != nil {
		t.Fatal(err)
	}
	if captured != published.Endpoint() {
		t.Fatalf("capture %#v does not match endpoint %#v", captured, published.Endpoint())
	}
	moved := node
	moved.Meta = cluster.NodeMeta{internode.MetadataPublicKey: published.PublicKey, internode.MetadataPort: "40003"}
	if captured, err := Capture(moved, published.Execution); err != nil || captured == published.Endpoint() {
		t.Fatalf("a moved listener matched the endpoint: %v", err)
	}
}

// The owner publishes its invite listener beside its supervisor; the address
// decodes on every later read, is a literal unicast or loopback endpoint, and
// is not part of the identity membership authenticates.
func TestDescriptorJoinListenerAddress(t *testing.T) {
	published := sample()
	published.Supervisor = "{forge@bee.hive:supervisor_host|0x1}"
	published.Join = "127.0.0.1:4410"
	data, err := json.Marshal(published)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := Decode(data)
	if err != nil || decoded != published {
		t.Fatalf("published join address decoded as %#v, %v", decoded, err)
	}
	if endpoint := published.Endpoint(); endpoint.Join != "" || endpoint.Supervisor != "" {
		t.Fatalf("endpoint keeps hints: %#v", endpoint)
	}
	for _, bad := range []string{"127.0.0.1:0", "0.0.0.0:4410", "join.example:4410", "[fe80::1%eth0]:4410", "127.0.0.1"} {
		invalid := published
		invalid.Join = bad
		if err := invalid.validate(); err == nil {
			t.Fatalf("join address %q was accepted", bad)
		}
	}
	if _, err := Decode(bytes.Replace(data, []byte(`"127.0.0.1:4410"`), []byte(`null`), 1)); err == nil {
		t.Fatal("a null join address was accepted")
	}
}

// The launch identity names the start request that produced this owner, so
// the client that started an owner can tell it won the state election.
func TestDescriptorLaunchIdentity(t *testing.T) {
	published := sample()
	published.Launch = strings.Repeat("b", 32)
	data, err := json.Marshal(published)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := Decode(data)
	if err != nil || decoded != published {
		t.Fatalf("launch identity decoded as %#v, %v", decoded, err)
	}
	if endpoint := published.Endpoint(); endpoint.Launch != "" {
		t.Fatalf("endpoint keeps the launch identity: %#v", endpoint)
	}
	for _, bad := range []string{"short", strings.Repeat("g", 32), strings.Repeat("A", 32)} {
		invalid := published
		invalid.Launch = bad
		if err := invalid.validate(); err == nil {
			t.Fatalf("launch identity %q was accepted", bad)
		}
	}
}
