//go:build meshclient

// SPDX-License-Identifier: MIT

// Package mesh starts a physical client's participation in Wippy's native mesh.
// Transport enrollment does not grant desktop or application access.
package mesh

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"fmt"
	"net/netip"
	"time"

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

const startupTimeout = 15 * time.Second

// loopbackGossipInterval is memberlist's loopback cadence. A client's mesh is
// a same-machine loopback pair, and its graceful leave waits for the leave
// broadcast to be gossiped, which the runtime's multi-node default of 500ms
// stretches to about a second of every client exit.
const loopbackGossipInterval = 100 * time.Millisecond
const cleanupTimeout = 3 * time.Second

// JoinConfig is selected by the native launcher, not by remote metadata.
type JoinConfig struct {
	// Directory holds the owner's rendezvous descriptor.
	Directory string
	// EnrollmentDirectory holds the owner-seeded local enrollment.
	EnrollmentDirectory string
	// Node and Key are the identity the owner enrolled for this client.
	Node string
	Key  ed25519.PrivateKey
	// TLS is the owner's mesh credential, which the owner and its local
	// clients share as one OS account. There is no plaintext fallback once it
	// is selected.
	TLS internode.ManagerTLSConfig
}

// Joined runs one client that already holds an enrolled identity against a
// same-machine owner over loopback. The owner seeded the enrollment with this
// exact node and public key. run begins only after an authenticated connection
// to the descriptor's pinned owner and a recheck of the exact published
// execution, endpoints and enrollment; it must still obtain supervisor
// admission and honor ctx. The owner is never started here.
func Joined(ctx context.Context, config JoinConfig, run func(context.Context, *stackpkg.Stack, rendezvous.Descriptor) error) (result error) {
	if ctx == nil || run == nil || config.Node == "" || len(config.Key) != ed25519.PrivateKeySize {
		return errors.New("mesh client: invalid enrolled identity")
	}
	store, err := rendezvous.New(config.Directory)
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
	transport, err := netip.ParseAddrPort(descriptor.Transport)
	if err != nil || !transport.Addr().IsLoopback() {
		return errors.New("mesh client: local owner must advertise loopback transport")
	}
	if endpoint.Addr().Is4() != transport.Addr().Is4() {
		return errors.New("mesh client: owner address families differ")
	}
	enrollment, err := rendezvous.NewEnrollment(config.EnrollmentDirectory)
	if err != nil {
		return err
	}
	snapshot, err := enrollment.Read(ctx, descriptor.Execution)
	if err != nil {
		return fmt.Errorf("mesh client: read enrollment: %w", err)
	}
	public := config.Key.Public().(ed25519.PublicKey)
	registered, ok := snapshot.PeerKey(config.Node)
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
		NodeName: config.Node, Logger: zap.NewNop(), Bus: bus, Collector: collector, Transcoder: payload.NewTranscoder(),
		MembershipBindAddr: loopback, MembershipAdvertise: loopback, InternodeBindAddr: loopback,
		SecretKey:                base64.StdEncoding.EncodeToString(snapshot.GossipKey()),
		InternodeIdentityKey:     base64.RawStdEncoding.EncodeToString(config.Key),
		InternodeTLS:             config.TLS,
		InternodeTrustedPeerKeys: map[string]string{config.Node: base64.RawStdEncoding.EncodeToString(public), descriptor.Node: descriptor.PublicKey},
		JoinAddrs:                []string{descriptor.Gossip},
		MembershipGossipInterval: loopbackGossipInterval,
		Meta:                     clusterapi.NodeMeta{"raft_eligible": "false", internode.MetadataSurfaceProtocol: "1"},
	})
	if err != nil {
		return err
	}
	defer func() { result = errors.Join(result, stack.Stop()) }()
	root, names, err := prepareNames(ctx, stack, bus)
	if err != nil {
		return err
	}
	defer func() { result = errors.Join(result, names.(boot.Stopper).Stop(context.WithoutCancel(root))) }()
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
	// Publishing a new execution and replacing the enrollment are separate
	// writes; either change after connection invalidates this join.
	current, err := store.Read(startup)
	if err != nil {
		return err
	}
	if current.Endpoint() != descriptor.Endpoint() {
		return rendezvous.ErrOwnerChanged
	}
	currentEnrollment, err := enrollment.Read(startup, descriptor.Execution)
	if err != nil {
		return err
	}
	if registered, ok := currentEnrollment.PeerKey(config.Node); !ok || !public.Equal(registered) {
		return errors.New("mesh client: enrollment retired before admission")
	}
	// The runtime retains Start's context for the live transport. Disarm only
	// the startup deadline, leaving caller cancellation attached to its lifetime.
	if !abortStartup() {
		return startup.Err()
	}
	if err := lifetime.Err(); err != nil {
		return err
	}
	return run(lifetime, stack, descriptor)
}

func awaitOwner(ctx context.Context, stack *stackpkg.Stack, expected rendezvous.Descriptor) error {
	ticker := time.NewTicker(20 * time.Millisecond)
	defer ticker.Stop()
	for {
		for _, node := range stack.ConnMgr.ConnectedNodes() {
			if node != expected.Node {
				continue
			}
			for _, member := range stack.Membership.Nodes() {
				if member.ID != expected.Node {
					continue
				}
				actual, err := rendezvous.Capture(member, expected.Execution)
				if err != nil {
					return err
				}
				if actual != expected.Endpoint() {
					return rendezvous.ErrOwnerChanged
				}
				return nil
			}
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("mesh client: authenticate owner: %w", ctx.Err())
		case <-ticker.C:
		}
	}
}
