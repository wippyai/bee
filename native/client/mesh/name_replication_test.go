//go:build meshclient && namereplication

// SPDX-License-Identifier: MIT
package mesh

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"testing"
	"time"

	"github.com/wippyai/runtime/api/pid"
	metricscfg "github.com/wippyai/runtime/api/service/metrics"
	topapi "github.com/wippyai/runtime/api/topology"
	stackpkg "github.com/wippyai/runtime/cluster"
	"github.com/wippyai/runtime/service/metrics"
	"github.com/wippyai/runtime/system/eventbus"
	"github.com/wippyai/runtime/system/payload"
	"go.uber.org/zap"
)

// TestEventualNameReplicatesOverGossip reports whether an EVENTUAL name
// registered on one raft-disabled node becomes visible on a joined peer.

func TestEventualNameReplicatesOverGossip(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		t.Fatal(err)
	}
	ownerPub, ownerKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	clientPub, clientKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	collector := metrics.NewCollector(metricscfg.Config{})
	defer collector.Close()
	config := func(node string, key ed25519.PrivateKey) stackpkg.StackConfig {
		return stackpkg.StackConfig{NodeName: node, Logger: zap.NewNop(), Bus: eventbus.NewBus(), Collector: collector, Transcoder: payload.NewTranscoder(),
			MembershipBindAddr: "127.0.0.1", InternodeBindAddr: "127.0.0.1",
			SecretKey: base64.StdEncoding.EncodeToString(secret), InternodeIdentityKey: base64.RawStdEncoding.EncodeToString(key),
			InternodeTrustedPeerKeys: map[string]string{node: base64.RawStdEncoding.EncodeToString(key.Public().(ed25519.PublicKey))}}
	}
	ownerCfg := config("owner", ownerKey)
	// The owner trusts the client's key, as the enrolled owner does.
	ownerCfg.InternodeTrustedPeerKeys["client"] = base64.RawStdEncoding.EncodeToString(clientPub)
	owner, err := stackpkg.AssembleStack(ownerCfg)
	if err != nil {
		t.Fatal(err)
	}
	defer owner.Stop()
	if err := owner.Start(ctx); err != nil {
		t.Fatal(err)
	}
	ownerRoot, ownerNames, err := prepareNames(ctx, owner, ownerCfg.Bus)
	if err != nil {
		t.Fatal(err)
	}
	defer stopNames(ownerRoot, ownerNames)

	clientCfg := config("client", clientKey)
	clientCfg.InternodeTrustedPeerKeys["owner"] = base64.RawStdEncoding.EncodeToString(ownerPub)
	clientCfg.InternodeTrustedPeerKeys["client"] = base64.RawStdEncoding.EncodeToString(clientPub)
	clientCfg.JoinAddrs = []string{owner.Membership.LocalNode().Addr}
	client, err := stackpkg.AssembleStack(clientCfg)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Stop()
	if err := client.Start(ctx); err != nil {
		t.Fatal(err)
	}
	clientRoot, clientNames, err := prepareNames(ctx, client, clientCfg.Bus)
	if err != nil {
		t.Fatal(err)
	}
	defer stopNames(clientRoot, clientNames)

	deadline := time.Now().Add(15 * time.Second)
	for len(owner.ConnMgr.ConnectedNodes()) != 1 || len(client.ConnMgr.ConnectedNodes()) != 1 {
		if time.Now().After(deadline) {
			t.Fatal("client did not authenticate")
		}
		time.Sleep(20 * time.Millisecond)
	}

	name := "bee.hive_host.supervisor/owner"
	ownerRegistry := topapi.GetEventualRegistry(ownerRoot)
	if ownerRegistry == nil {
		t.Fatal("owner eventual registry missing")
	}
	clientRegistry := topapi.GetEventualRegistry(clientRoot)
	if clientRegistry == nil {
		t.Fatal("client eventual registry missing")
	}
	if _, err := ownerRegistry.Register(name, pid.PID{Node: "owner", Host: "bee.hive_host:supervisor_host", UniqID: "0xabc"}); err != nil {
		t.Fatalf("owner register: %v", err)
	}
	deadline = time.Now().Add(12 * time.Second)
	for time.Now().Before(deadline) {
		found, err := clientRegistry.Lookup(clientRoot, name)
		if err == nil && found.Found {
			t.Logf("REPLICATED after %v: %v", time.Since(deadline.Add(-12*time.Second)), found.PID)
			return
		}
		time.Sleep(200 * time.Millisecond)
	}
	t.Fatal("EVENTUAL name never replicated to the joined peer")
}

func stopNames(ctx context.Context, component any) {
	if stopper, ok := component.(interface{ Stop(context.Context) error }); ok {
		_ = stopper.Stop(context.WithoutCancel(ctx))
	}
}
