//go:build rendezvousintegration

// SPDX-License-Identifier: MIT

package rendezvous

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/wippyai/runtime/api/cluster"
	metricscfg "github.com/wippyai/runtime/api/service/metrics"
	"github.com/wippyai/runtime/application/statelock"
	stackpkg "github.com/wippyai/runtime/cluster"
	"github.com/wippyai/runtime/service/metrics"
	"github.com/wippyai/runtime/system/eventbus"
	"github.com/wippyai/runtime/system/payload"
	"go.uber.org/zap"
)

func TestProtectedEnrollmentAdmitsLiveMeshClient(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	state := t.TempDir()
	unlock, err := statelock.Acquire(state)
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	e, err := NewEnrollment(filepath.Join(state, "discovery"))
	if err != nil {
		t.Fatal(err)
	}
	execution := sample().Execution
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		t.Fatal(err)
	}
	if err := e.Initialize(ctx, execution, secret); err != nil {
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
	denied := make(chan struct{})
	var deniedOnce sync.Once
	ownerConfig := config("owner", ownerKey)
	ownerConfig.InternodePeerKeySource = cluster.PeerKeySource(func(node string) (ed25519.PublicKey, bool) {
		key, ok := e.Resolve(ctx, execution, node)
		if node == "client" && !ok {
			deniedOnce.Do(func() { close(denied) })
		}
		return key, ok
	})
	owner, err := stackpkg.AssembleStack(ownerConfig)
	if err != nil {
		t.Fatal(err)
	}
	defer owner.Stop()
	if err := owner.Start(ctx); err != nil {
		t.Fatal(err)
	}
	clientConfig := config("client", clientKey)
	clientConfig.InternodeTrustedPeerKeys["owner"] = base64.RawStdEncoding.EncodeToString(ownerPub)
	clientConfig.JoinAddrs = []string{owner.Membership.LocalNode().Addr}
	client, err := stackpkg.AssembleStack(clientConfig)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Stop()
	if err := client.Start(ctx); err != nil {
		t.Fatal(err)
	}
	// Knowing the shared gossip secret does not authorize an unregistered key.
	select {
	case <-denied:
	case <-ctx.Done():
		t.Fatal("missing denial before enrollment")
	}
	if len(owner.ConnMgr.ConnectedNodes()) != 0 {
		t.Fatal("unregistered identity connected")
	}
	if _, err := e.Register(ctx, execution, "client", clientPub); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(12 * time.Second)
	for len(owner.ConnMgr.ConnectedNodes()) != 1 || len(client.ConnMgr.ConnectedNodes()) != 1 {
		if time.Now().After(deadline) {
			t.Fatal("registered client did not authenticate")
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err := e.Remove(ctx, execution, "client", clientPub); err != nil {
		t.Fatal(err)
	}
	if _, ok := ownerConfig.InternodePeerKeySource("client"); ok {
		t.Fatal("removed key remained available to new handshakes")
	}
}
