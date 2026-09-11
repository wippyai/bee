//go:build meshclient

// SPDX-License-Identifier: MIT

// Package localowner composes local bootstrap with Wippy's normal owner boot.
// It creates no transport, workspace database, process, or admission grant.
package localowner

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"net/netip"
	"path/filepath"
	"sync"
	"time"

	"github.com/wippyai/bee/native/hive/localtls"
	"github.com/wippyai/bee/native/hive/rendezvous"
	"github.com/wippyai/runtime/api/boot"
	clusterapi "github.com/wippyai/runtime/api/cluster"
	app "github.com/wippyai/runtime/cmd/app"
)

const DirectoryName = rendezvous.DirectoryName

// Options comes from the native host. Node is the selected runtime node name,
// not a workspace identity. Lifetime must be finite and at most 30 days.
type Options struct {
	Node          string
	Lifetime      time.Duration
	HiveDirectory string // Host-selected shared same-account bootstrap; empty is an isolated host composition.
}

type prepared struct {
	execution string
	directory string
	publicKey string
	expires   time.Time
	ctx       context.Context
	cancel    context.CancelFunc
}

// Component is one owner invocation. The application's native launcher prepares
// it only through cmd/app's owner runner and includes this boot component.
// Construction and Load perform no filesystem or network operations.
type Component struct {
	options Options
	mu      sync.Mutex
	used    bool
	state   *prepared
}

func New(options Options) (*Component, error) {
	if options.HiveDirectory != "" && !filepath.IsAbs(options.HiveDirectory) {
		return nil, errors.New("local Hive directory must be absolute")
	}
	if len(options.Node) == 0 || len(options.Node) > 128 || options.Lifetime < time.Second || options.Lifetime > 30*24*time.Hour {
		return nil, errors.New("invalid local owner options")
	}
	for _, character := range options.Node {
		if character < 33 || character > 126 {
			return nil, errors.New("invalid local owner node")
		}
	}
	return &Component{options: options}, nil
}

func (c *Component) Name() string        { return "bee.hive.local_owner" }
func (c *Component) DependsOn() []string { return []string{"cluster"} }
func (c *Component) Load(ctx context.Context) (context.Context, error) {
	c.mu.Lock()
	state := c.state
	c.mu.Unlock()
	if state != nil {
		deadline, ok := ctx.Deadline()
		if !ok || deadline.After(state.expires) {
			return ctx, errors.New("local owner boot lost execution deadline")
		}
	}
	return ctx, nil
}

// PrepareOwner is called only by cmd/app's runOwner callback. The runtime holds
// its application state lock throughout this method, native boot, shutdown, and
// returned cleanup.
func (c *Component) PrepareOwner(ctx context.Context, request app.LaunchRequest) (app.OwnerResources, error) {
	return c.prepareOwner(ctx, request, false)
}

// PrepareProjectOwner gives each selected project state a stable mesh identity.
// The display label alone cannot identify nodes: several projects share a host.
func (c *Component) PrepareProjectOwner(ctx context.Context, request app.LaunchRequest) (app.OwnerResources, error) {
	return c.prepareOwner(ctx, request, true)
}

func (c *Component) prepareOwner(ctx context.Context, request app.LaunchRequest, project bool) (app.OwnerResources, error) {
	if ctx == nil || request.StateDir == "" {
		return app.OwnerResources{}, errors.New("local owner requires ordinary lock-held application startup")
	}
	if err := ctx.Err(); err != nil {
		return app.OwnerResources{}, err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.used {
		return app.OwnerResources{}, errors.New("local owner component already used")
	}
	if project {
		state, err := filepath.EvalSymlinks(request.StateDir)
		if err != nil {
			return app.OwnerResources{}, err
		}
		digest := sha256.Sum256([]byte(filepath.Clean(state)))
		label := c.options.Node
		if len(label) > 95 {
			label = label[:95]
		}
		c.options.Node = label + "-" + hex.EncodeToString(digest[:16])
	}
	c.used = true
	var execution [16]byte
	if _, err := rand.Read(execution[:]); err != nil {
		return app.OwnerResources{}, err
	}
	directory := filepath.Join(request.StateDir, DirectoryName)
	executionID := hex.EncodeToString(execution[:])
	var credentials localtls.Credentials
	var err error
	if c.options.HiveDirectory != "" {
		credentials, err = localtls.PrepareShared(ctx, directory, executionID, time.Now().Add(c.options.Lifetime), c.options.HiveDirectory)
	} else {
		credentials, err = localtls.Prepare(ctx, directory, executionID, time.Now().Add(c.options.Lifetime))
	}
	if err != nil {
		return app.OwnerResources{}, err
	}
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return app.OwnerResources{}, err
	}
	var shared *rendezvous.Enrollment
	var sharedEpoch string
	secret := make([]byte, 32)
	if c.options.HiveDirectory != "" {
		shared, err = rendezvous.NewEnrollment(c.options.HiveDirectory)
		if err != nil {
			return app.OwnerResources{}, err
		}
		var snapshot rendezvous.Snapshot
		sharedEpoch, snapshot, err = shared.EnsureShared(ctx)
		if err != nil {
			return app.OwnerResources{}, err
		}
		secret = snapshot.GossipKey()
	} else if _, err := rand.Read(secret); err != nil {
		return app.OwnerResources{}, err
	}
	enrollment, err := rendezvous.NewEnrollment(directory)
	if err != nil {
		return app.OwnerResources{}, err
	}
	if err := enrollment.Initialize(ctx, executionID, secret); err != nil {
		return app.OwnerResources{}, err
	}
	lifetime, cancel := context.WithDeadline(ctx, credentials.ExpiresAt)
	var sharedLease *rendezvous.PeerLease
	if shared != nil {
		sharedLease, _, err = shared.RegisterHeld(lifetime, sharedEpoch, c.options.Node, public)
		if err != nil {
			cancel()
			return app.OwnerResources{}, err
		}
	}
	state := &prepared{execution: executionID, directory: directory, publicKey: base64.RawStdEncoding.EncodeToString(public), expires: credentials.ExpiresAt, ctx: lifetime, cancel: cancel}
	c.state = state
	peerKeys := clusterapi.PeerKeySource(func(node string) (ed25519.PublicKey, bool) {
		if key, ok := enrollment.Resolve(lifetime, executionID, node); ok {
			return key, true
		}
		if shared != nil {
			return shared.Resolve(lifetime, sharedEpoch, node)
		}
		return nil, false
	})
	config := boot.NewConfig(
		boot.WithSection("relay", map[string]any{"node_name": c.options.Node}),
		boot.WithSection("cluster", map[string]any{
			"enabled": true, "name": c.options.Node, "raft.enabled": false, "raft.role": "client",
			"membership.bind_addr": "127.0.0.1", "membership.bind_port": 0, "membership.advertise_addr": "127.0.0.1", "membership.join_addrs": "",
			"membership.secret_key": base64.StdEncoding.EncodeToString(secret), "membership.secret_file": "",
			"internode.bind_addr": "127.0.0.1", "internode.bind_port": 0, "internode.auto_port": true,
			"internode.advertise_addr": "127.0.0.1", "internode.advertise_port": 0,
			"internode.identity_key": base64.RawStdEncoding.EncodeToString(private), "internode.identity_key_file": "",
			"internode.trusted_peer_keys." + c.options.Node: state.publicKey, "internode.peer_key_source": peerKeys,
			"internode.tls.enabled": true, "internode.tls.cert_file": credentials.TLS.CertFile,
			"internode.tls.key_file": credentials.TLS.KeyFile, "internode.tls.ca_file": credentials.TLS.CAFile,
		}),
	)
	return app.OwnerResources{Config: config, Deadline: credentials.ExpiresAt, Close: func() error {
		cancel()
		if sharedLease != nil {
			cleanup, stop := context.WithTimeout(context.WithoutCancel(ctx), 3*time.Second)
			defer stop()
			return sharedLease.Close(cleanup)
		}
		return nil
	}}, nil
}

// Start publishes transport hints only after the normal native cluster starts.
// It verifies that the live identity and loopback endpoints match this execution.
// Successful publication is not workspace readiness or client admission.
func (c *Component) Start(ctx context.Context) error {
	c.mu.Lock()
	state := c.state
	c.mu.Unlock()
	if state == nil {
		return nil
	} // Reserved operations do not prepare an owner.
	if err := state.ctx.Err(); err != nil {
		return err
	}
	membership := clusterapi.GetMembership(ctx)
	if membership == nil {
		return errors.New("local owner requires native cluster boot")
	}
	descriptor, err := rendezvous.Capture(membership.LocalNode(), state.execution)
	if err != nil {
		return err
	}
	if descriptor.Node != c.options.Node || descriptor.PublicKey != state.publicKey {
		return errors.New("local owner native identity mismatch")
	}
	for _, address := range []string{descriptor.Gossip, descriptor.Transport} {
		endpoint, err := netip.ParseAddrPort(address)
		if err != nil || !endpoint.Addr().IsLoopback() {
			return errors.New("local owner requires loopback endpoints")
		}
	}
	store, err := rendezvous.New(state.directory)
	if err != nil {
		return err
	}
	return store.Publish(state.ctx, descriptor)
}

// Stop closes bootstrap admission but leaves native transport cleanup to Wippy.
// Discovery remains a stale hint after shutdown; no successor's files are removed.
func (c *Component) Stop(context.Context) error {
	c.mu.Lock()
	state := c.state
	c.mu.Unlock()
	if state != nil {
		state.cancel()
	}
	return nil
}
