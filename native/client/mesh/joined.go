//go:build meshclient

// SPDX-License-Identifier: MIT
package mesh

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"fmt"
	"net/netip"

	"github.com/wippyai/bee/native/hive/rendezvous"
	"github.com/wippyai/runtime/api/boot"
	clusterapi "github.com/wippyai/runtime/api/cluster"
	metricscfg "github.com/wippyai/runtime/api/service/metrics"
	stackpkg "github.com/wippyai/runtime/cluster"
	"github.com/wippyai/runtime/cluster/internode"
	"github.com/wippyai/runtime/service/metrics"
	"github.com/wippyai/runtime/system/eventbus"
	"github.com/wippyai/runtime/system/payload"
	"go.uber.org/zap"
)

// Joined runs one client that already holds an enrolled identity against a
// same-machine owner over plaintext loopback. The owner seeded the enrollment
// with this exact node and public key, so the handshake resolves without TLS
// credentials. run must honor ctx.
func Joined(ctx context.Context, directory, enrollmentDirectory, node string, private ed25519.PrivateKey, run func(context.Context, *stackpkg.Stack, rendezvous.Descriptor) error) error {
	if ctx == nil || run == nil || node == "" || len(private) != ed25519.PrivateKeySize {
		return errors.New("mesh client: invalid enrolled identity")
	}
	store, err := rendezvous.New(directory)
	if err != nil {
		return err
	}
	descriptor, err := store.Read(ctx)
	if err != nil {
		return fmt.Errorf("mesh client: read owner: %w", err)
	}
	// Same-machine enrollment only: never disclose the local bootstrap to a
	// remote endpoint selected by a descriptor.
	endpoint, err := netip.ParseAddrPort(descriptor.Gossip)
	if err != nil || !endpoint.Addr().IsLoopback() {
		return errors.New("mesh client: local owner must advertise loopback gossip")
	}
	enrollment, err := rendezvous.NewEnrollment(enrollmentDirectory)
	if err != nil {
		return err
	}
	snapshot, err := enrollment.Read(ctx, descriptor.Execution)
	if err != nil {
		return fmt.Errorf("mesh client: read enrollment: %w", err)
	}
	public := private.Public().(ed25519.PublicKey)
	registered, ok := snapshot.PeerKey(node)
	if !ok || !public.Equal(registered) {
		return errors.New("mesh client: this node is not enrolled with the owner")
	}
	collector := metrics.NewCollector(metricscfg.Config{})
	defer collector.Close()
	loopback := "127.0.0.1"
	if endpoint.Addr().Is6() {
		loopback = "::1"
	}
	bus := eventbus.NewBus()
	stack, err := stackpkg.AssembleStack(stackpkg.StackConfig{
		NodeName: node, Logger: zap.NewNop(), Bus: bus, Collector: collector, Transcoder: payload.NewTranscoder(),
		MembershipBindAddr: loopback, MembershipAdvertise: loopback, InternodeBindAddr: loopback,
		SecretKey:                base64.StdEncoding.EncodeToString(snapshot.GossipKey()),
		InternodeIdentityKey:     base64.RawStdEncoding.EncodeToString(private),
		InternodeTrustedPeerKeys: map[string]string{node: base64.RawStdEncoding.EncodeToString(public), descriptor.Node: descriptor.PublicKey},
		JoinAddrs:                []string{descriptor.Gossip},
		Meta:                     clusterapi.NodeMeta{"raft_eligible": "false", internode.MetadataSurfaceProtocol: "1"},
	})
	if err != nil {
		return err
	}
	defer func() { _ = stack.Stop() }()
	root, names, err := prepareNames(ctx, stack, bus)
	if err != nil {
		return err
	}
	defer func() { _ = names.(boot.Stopper).Stop(context.WithoutCancel(root)) }()
	lifetime, endLifetime := context.WithCancel(root)
	defer endLifetime()
	startup, cancel := context.WithTimeout(ctx, startupTimeout)
	defer cancel()
	abortStartup := context.AfterFunc(startup, endLifetime)
	defer abortStartup()
	if err = stack.Start(lifetime); err != nil {
		return fmt.Errorf("mesh client: start native mesh: %w", err)
	}
	if err = names.(boot.Starter).Start(lifetime); err != nil {
		return err
	}
	if err = awaitOwner(startup, stack, descriptor); err != nil {
		return err
	}
	if !abortStartup() {
		return startup.Err()
	}
	if err := lifetime.Err(); err != nil {
		return err
	}
	return run(lifetime, stack, descriptor)
}
