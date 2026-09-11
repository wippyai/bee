//go:build meshclient

// SPDX-License-Identifier: MIT

// Package mesh starts a physical client's participation in Wippy's native mesh.
// Transport enrollment does not grant desktop or application access.
package mesh

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net/netip"
	"time"

	"github.com/wippyai/bee/native/hive/localtls"
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

// Cold network links may need time to become usable; cancellation remains immediate.
const startupTimeout = 60 * time.Second
const cleanupTimeout = 3 * time.Second

// LocalConfig is selected by the native launcher, not by remote metadata.
// TLS uses the runtime's existing certificate/key/CA files. There is no fallback
// from a selected TLS connection to plaintext.
type LocalConfig struct {
	Directory      string
	TLS            internode.ManagerTLSConfig
	StartupTimeout time.Duration // Optional same-machine authentication bound.
}

// Local runs one freshly enrolled client against an existing same-account owner.
// It never acquires the application's state lock or opens an application database.
// run begins only after an authenticated connection to the descriptor's pinned
// owner and a recheck of the exact published execution and endpoints. run must
// still obtain supervisor admission and fresh recipient-bound viewport grants.
// The stack and credentials are valid only for run's duration; run must honor ctx.
// The owner is never started as a fallback. No launch request or input is retried.
func Local(ctx context.Context, config LocalConfig, run func(context.Context, *stackpkg.Stack, rendezvous.Descriptor) error) error {
	return local(ctx, config, run, false)
}

// SameAccount loads execution-bound TLS credentials after checking loopback
// discovery. It never starts an owner or falls back to plaintext. Supervisor
// admission is still required; this is not remote enrollment.
func SameAccount(ctx context.Context, directory string, run func(context.Context, *stackpkg.Stack, rendezvous.Descriptor) error) error {
	return local(ctx, LocalConfig{Directory: directory}, run, true)
}

// SameAccountWithStartupTimeout keeps the live client lifetime tied to ctx, but
// bounds only initial same-machine owner authentication. It is used when a
// retained local descriptor may outlive an abruptly terminated owner.
func SameAccountWithStartupTimeout(ctx context.Context, directory string, timeout time.Duration, run func(context.Context, *stackpkg.Stack, rendezvous.Descriptor) error) error {
	return local(ctx, LocalConfig{Directory: directory, StartupTimeout: timeout}, run, true)
}

func local(ctx context.Context, config LocalConfig, run func(context.Context, *stackpkg.Stack, rendezvous.Descriptor) error, sameAccount bool) (result error) {
	if ctx == nil || run == nil {
		return errors.New("mesh client: context and client callback are required")
	}
	store, err := rendezvous.New(config.Directory)
	if err != nil {
		return err
	}
	descriptor, err := store.Read(ctx)
	if err != nil {
		return fmt.Errorf("mesh client: read owner: %w", err)
	}
	// This path is same-machine enrollment, not remote invitations. Never disclose
	// the local bootstrap secret to a remote endpoint selected by a descriptor.
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
	if sameAccount {
		credentials, err := localtls.Load(ctx, config.Directory, descriptor.Execution)
		if err != nil {
			return fmt.Errorf("mesh client: local TLS credentials: %w", err)
		}
		config.TLS = credentials.TLS
		var cancel context.CancelFunc
		ctx, cancel = context.WithDeadline(ctx, credentials.ExpiresAt)
		defer cancel()
	}
	enrollment, err := rendezvous.NewEnrollment(config.Directory)
	if err != nil {
		return err
	}
	snapshot, err := enrollment.Read(ctx, descriptor.Execution)
	if err != nil {
		return fmt.Errorf("mesh client: read enrollment: %w", err)
	}
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	var id [16]byte
	if _, err = rand.Read(id[:]); err != nil {
		return err
	}
	node := "bee-client-" + hex.EncodeToString(id[:])
	lease, snapshot, err := enrollment.RegisterHeld(ctx, descriptor.Execution, node, public)
	if err != nil {
		return err
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), cleanupTimeout)
		defer cancel()
		if err := lease.Close(cleanup); err != nil {
			result = errors.Join(result, fmt.Errorf("mesh client: retire enrollment: %w", err))
		}
	}()
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
		// This client only joins over loopback. A shorter gossip interval keeps
		// graceful membership leave responsive, at the cost of more local gossip.
		MembershipGossipInterval: 50 * time.Millisecond,
		SecretKey:                base64.StdEncoding.EncodeToString(snapshot.GossipKey()),
		InternodeIdentityKey:     base64.RawStdEncoding.EncodeToString(private),
		InternodeTLS:             config.TLS,
		InternodeTrustedPeerKeys: map[string]string{node: base64.RawStdEncoding.EncodeToString(public), descriptor.Node: descriptor.PublicKey},
		JoinAddrs:                []string{descriptor.Gossip},
		Meta:                     clusterapi.NodeMeta{"raft_eligible": "false", "bee.role": "client", internode.MetadataSurfaceProtocol: "1"},
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
	timeout := startupTimeout
	if config.StartupTimeout > 0 {
		timeout = config.StartupTimeout
	}
	startup, cancel := context.WithTimeout(ctx, timeout)
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
	current, err := store.Read(startup)
	if err != nil {
		return err
	}
	if current != descriptor {
		return rendezvous.ErrOwnerChanged
	}
	// Revalidate enrollment too: publishing a new execution and replacing the
	// bootstrap are separate writes. Either change invalidates this admission.
	currentEnrollment, err := enrollment.Read(startup, descriptor.Execution)
	if err != nil {
		return err
	}
	registered, ok := currentEnrollment.PeerKey(node)
	if !ok || !public.Equal(registered) {
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
				if actual != expected {
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
