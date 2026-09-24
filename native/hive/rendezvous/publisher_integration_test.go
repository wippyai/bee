//go:build rendezvousintegration

// SPDX-License-Identifier: MIT

package rendezvous

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"net"
	"path/filepath"
	"strings"
	"testing"

	"github.com/wippyai/runtime/api/boot"
	clusterapi "github.com/wippyai/runtime/api/cluster"
	ctxapi "github.com/wippyai/runtime/api/context"
	metricscfg "github.com/wippyai/runtime/api/service/metrics"
	"github.com/wippyai/runtime/cluster"
	app "github.com/wippyai/runtime/cmd/app"
	"github.com/wippyai/runtime/service/metrics"
	"github.com/wippyai/runtime/system/eventbus"
	"github.com/wippyai/runtime/system/payload"
	"go.uber.org/zap"
)

func TestPublisherUsesRetainedNativeEndpointUnderOwnerLock(t *testing.T) {
	state := t.TempDir()
	unlock, err := holdState(t, state)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := unlock(); err != nil {
			t.Error(err)
		}
	}()
	pub, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		t.Fatal(err)
	}
	collector := metrics.NewCollector(metricscfg.Config{})
	defer collector.Close()
	stack, err := cluster.AssembleStack(cluster.StackConfig{
		NodeName: "retained-owner", Logger: zap.NewNop(), Bus: eventbus.NewBus(),
		Collector: collector, Transcoder: payload.NewTranscoder(),
		MembershipBindAddr: "127.0.0.1", InternodeBindAddr: "127.0.0.1",
		SecretKey:                base64.StdEncoding.EncodeToString(secret),
		InternodeIdentityKey:     base64.RawStdEncoding.EncodeToString(key),
		InternodeTrustedPeerKeys: map[string]string{"retained-owner": base64.RawStdEncoding.EncodeToString(pub)},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer stack.Stop()
	ctx := ctxapi.WithAppContext(context.Background(), ctxapi.NewAppContext())
	ctx = clusterapi.WithMembership(ctx, stack.Membership)
	dir := filepath.Join(state, "discovery")
	publisher, err := Publisher(dir, sample().Execution, strings.Repeat("c", 32))
	if err != nil {
		t.Fatal(err)
	}
	start := publisher.(boot.Starter)
	if err := start.Start(ctx); err == nil {
		t.Fatal("published before native startup")
	}
	if err := stack.Start(ctx); err != nil {
		t.Fatal(err)
	}
	if err := start.Start(ctx); err != nil {
		t.Fatal(err)
	}
	// A second process uses this read path, not the owner's application lock.
	store, err := New(dir)
	if err != nil {
		t.Fatal(err)
	}
	d, err := store.Read(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if d.Node != "retained-owner" || d.Gossip != stack.Membership.LocalNode().Addr || d.Launch != strings.Repeat("c", 32) {
		t.Fatal("wrong live owner", d)
	}
	probe, err := net.Listen("tcp", d.Transport)
	if probe != nil {
		_ = probe.Close()
	}
	if err == nil {
		t.Fatal("published transport port was not retained")
	}
	if owned, err := app.Owned(state); err != nil || !owned {
		t.Fatalf("client read disturbed owner exclusion: owned=%v err=%v", owned, err)
	}
	if err := stack.Stop(); err != nil {
		t.Fatal(err)
	}
	stale, err := store.Read(context.Background())
	if err != nil || stale != d {
		t.Fatal("shutdown erased or changed discovery hint")
	}
	probe, err = net.Listen("tcp", d.Transport)
	if err != nil {
		t.Fatal("native shutdown did not release socket", err)
	}
	_ = probe.Close()
}
