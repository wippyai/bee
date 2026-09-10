// SPDX-License-Identifier: MIT

package rendezvous

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
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
	component, err := Publisher(dir, d.Execution)
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
