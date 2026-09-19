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
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	machineconfig "github.com/wippyai/bee/native/hive/config"
	"github.com/wippyai/bee/native/hive/localtls"
	"github.com/wippyai/bee/native/hive/rendezvous"
	app "github.com/wippyai/runtime/cmd/app"
	"github.com/wippyai/runtime/api/boot"
	clusterapi "github.com/wippyai/runtime/api/cluster"
	"github.com/wippyai/runtime/cluster/internode"
)

const DirectoryName = rendezvous.DirectoryName

// Options comes from the native host. Node is the selected runtime node name,
// not a workspace identity. Lifetime must be finite and at most 30 days.
type Options struct {
	Node            string
	Lifetime        time.Duration
	HiveDirectory   string // Host-selected shared same-account bootstrap; empty is an isolated host composition.
	ConfigDirectory string // Host-selected protected machine configuration; empty selects local mode.
}

type prepared struct {
	execution string
	directory string
	node      string
	publicKey string
	joined    bool
	gossip    netip.Addr
	transport netip.Addr
	expires   time.Time
	ctx       context.Context
	cancel    context.CancelFunc
	// releaseBoot cancels the boot context bound this owner installed in Load.
	releaseBoot context.CancelFunc
}

// Component is one owner invocation. The application's single native launcher
// installs PrepareOwner into its LaunchPlan and includes this boot component.
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
// Load installs this owner's execution credential as the bound on the running
// runtime. The old contract carried the same bound as an owner deadline the
// runner applied to its context; the host now installs it directly, so the
// bound reaches every component loaded after this one and ends the runtime at
// expiry. The bound is released with the owner on Stop.
func (c *Component) Load(ctx context.Context) (context.Context, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	state := c.state
	if state == nil {
		return ctx, nil
	}
	if err := ctx.Err(); err != nil {
		return ctx, err
	}
	if deadline, ok := ctx.Deadline(); ok && !deadline.After(state.expires) {
		return ctx, nil
	}
	bounded, cancel := context.WithDeadline(ctx, state.expires)
	if err := bounded.Err(); err != nil {
		cancel()
		return ctx, errors.New("local owner boot lost execution deadline")
	}
	if state.releaseBoot != nil {
		state.releaseBoot()
	}
	state.releaseBoot = cancel
	return bounded, nil
}

// PrepareOwner opens this owner invocation's host resources. The runtime calls
// it as the host's Plan.Prepare, so it runs under the real application state
// lock and its close runs after runtime shutdown while that lock is still held.
func (c *Component) PrepareOwner(ctx context.Context, l app.Launch) (boot.Config, func() error, error) {
	return c.prepareOwner(ctx, l, false)
}

// PrepareProjectOwner gives each selected project state a stable mesh identity.
// The display label alone cannot identify nodes: several projects share a host.
func (c *Component) PrepareProjectOwner(ctx context.Context, l app.Launch) (boot.Config, func() error, error) {
	return c.prepareOwner(ctx, l, true)
}

func (c *Component) prepareOwner(ctx context.Context, l app.Launch, project bool) (boot.Config, func() error, error) {
	if ctx == nil || l.Op != app.OpRun || l.State == "" {
		return nil, nil, errors.New("local owner requires ordinary lock-held application startup")
	}
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.used {
		return nil, nil, errors.New("local owner component already used")
	}
	if project {
		state, err := filepath.EvalSymlinks(l.State)
		if err != nil {
			return nil, nil, err
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
		return nil, nil, err
	}
	directory := filepath.Join(l.State, DirectoryName)
	executionID := hex.EncodeToString(execution[:])
	profile, joined, err := c.savedProfile(ctx)
	if err != nil {
		return nil, nil, err
	}
	nodeName := c.options.Node
	if joined {
		nodeName = profile.NodeID
	}
	gossip, transport := netip.MustParseAddr("127.0.0.1"), netip.MustParseAddr("127.0.0.1")
	if joined {
		gossip, err = localAlias(profile.MembershipBindAddress)
		if err != nil {
			return nil, nil, err
		}
		transport, err = localAlias(profile.InternodeBindAddress)
		if err != nil {
			return nil, nil, err
		}
	}
	var credentials localtls.Credentials
	switch {
	case joined:
		credentials, err = localtls.SnapshotJoined(ctx, directory, executionID, internode.ManagerTLSConfig{
			Enabled: true, CertFile: profile.TLSCertPath, KeyFile: profile.TLSKeyPath, CAFile: profile.TLSCAPath,
		})
	case c.options.HiveDirectory != "":
		credentials, err = localtls.PrepareShared(ctx, directory, executionID, time.Now().Add(c.options.Lifetime), c.options.HiveDirectory)
	default:
		credentials, err = localtls.Prepare(ctx, directory, executionID, time.Now().Add(c.options.Lifetime))
	}
	if err != nil {
		return nil, nil, err
	}
	var public ed25519.PublicKey
	var private ed25519.PrivateKey
	if joined {
		privateBytes, decodeErr := base64.StdEncoding.DecodeString(string(profile.InternodePrivateKey))
		if decodeErr != nil {
			return nil, nil, decodeErr
		}
		private = ed25519.PrivateKey(privateBytes)
		public = private.Public().(ed25519.PublicKey)
	} else {
		public, private, err = ed25519.GenerateKey(rand.Reader)
		if err != nil {
			return nil, nil, err
		}
	}
	var shared *rendezvous.Enrollment
	var sharedEpoch string
	secret := make([]byte, 32)
	switch {
	case joined:
		secret, err = base64.StdEncoding.DecodeString(string(profile.MembershipSecret))
		if err != nil {
			return nil, nil, err
		}
	case c.options.HiveDirectory != "":
		shared, err = rendezvous.NewEnrollment(c.options.HiveDirectory)
		if err != nil {
			return nil, nil, err
		}
		var snapshot rendezvous.Snapshot
		sharedEpoch, snapshot, err = shared.EnsureShared(ctx)
		if err != nil {
			return nil, nil, err
		}
		secret = snapshot.GossipKey()
	default:
		if _, err := rand.Read(secret); err != nil {
			return nil, nil, err
		}
	}
	enrollment, err := rendezvous.NewEnrollment(directory)
	if err != nil {
		return nil, nil, err
	}
	if err := enrollment.Initialize(ctx, executionID, secret); err != nil {
		return nil, nil, err
	}
	lifetime, cancel := context.WithDeadline(ctx, credentials.ExpiresAt)
	var sharedLease *rendezvous.PeerLease
	if shared != nil {
		sharedLease, _, err = shared.RegisterHeld(lifetime, sharedEpoch, c.options.Node, public)
		if err != nil {
			cancel()
			return nil, nil, err
		}
	}
	state := &prepared{
		execution: executionID, directory: directory, node: nodeName,
		publicKey: base64.RawStdEncoding.EncodeToString(public),
		joined:    joined, gossip: gossip, transport: transport,
		expires: credentials.ExpiresAt, ctx: lifetime, cancel: cancel,
	}
	c.state = state
	peerKeys := clusterapi.PeerKeySource(func(node string) (ed25519.PublicKey, bool) {
		// Physical clients enroll under this exact owner execution before joining.
		// Their keys are local rendezvous state, never Hive profile metadata.
		if key, ok := enrollment.Resolve(lifetime, executionID, node); ok {
			return key, true
		}
		if joined {
			encoded, ok := profile.PeerPublicKeys[node]
			if !ok {
				return nil, false
			}
			decoded, decodeErr := base64.StdEncoding.DecodeString(encoded)
			return ed25519.PublicKey(decoded), decodeErr == nil && len(decoded) == ed25519.PublicKeySize
		}
		if shared != nil {
			return shared.Resolve(lifetime, sharedEpoch, node)
		}
		return nil, false
	})
	clusterSettings := map[string]any{
		"enabled": true, "name": nodeName, "raft.enabled": false, "raft.role": "client",
		"membership.bind_addr": "127.0.0.1", "membership.bind_port": 0, "membership.advertise_addr": "127.0.0.1", "membership.join_addrs": "",
		"membership.secret_key": base64.StdEncoding.EncodeToString(secret), "membership.secret_file": "",
		"internode.bind_addr": "127.0.0.1", "internode.bind_port": 0, "internode.auto_port": true,
		"internode.advertise_addr": "127.0.0.1", "internode.advertise_port": 0,
		"internode.identity_key": base64.RawStdEncoding.EncodeToString(private), "internode.identity_key_file": "",
		"internode.trusted_peer_keys." + nodeName: state.publicKey, "internode.peer_key_source": peerKeys,
		"internode.tls.enabled": true, "internode.tls.cert_file": credentials.TLS.CertFile,
		"internode.tls.key_file": credentials.TLS.KeyFile, "internode.tls.ca_file": credentials.TLS.CAFile,
	}
	if joined {
		clusterSettings["membership.bind_addr"] = profile.MembershipBindAddress
		clusterSettings["membership.bind_port"] = int(profile.MembershipBindPort)
		clusterSettings["membership.advertise_addr"] = profile.MembershipAdvertiseAddress
		clusterSettings["membership.advertise_port"] = int(profile.MembershipAdvertisePort)
		clusterSettings["membership.join_addrs"] = strings.Join(profile.Seeds, ",")
		clusterSettings["internode.bind_addr"] = profile.InternodeBindAddress
		clusterSettings["internode.bind_port"] = int(profile.InternodeBindPort)
		clusterSettings["internode.auto_port"] = profile.InternodeBindPort == 0
		clusterSettings["internode.advertise_addr"] = profile.InternodeAdvertiseAddress
		clusterSettings["internode.advertise_port"] = int(profile.InternodeAdvertisePort)
		for node, key := range profile.PeerPublicKeys {
			clusterSettings["internode.trusted_peer_keys."+node] = key
		}
	}
	config := boot.NewConfig(
		boot.WithSection("relay", map[string]any{"node_name": nodeName}),
		boot.WithSection("cluster", clusterSettings),
	)
	return config, func() error {
		cancel()
		if sharedLease != nil {
			cleanup, stop := context.WithTimeout(context.WithoutCancel(ctx), 3*time.Second)
			defer stop()
			return sharedLease.Close(cleanup)
		}
		return nil
	}, nil
}

// savedProfile reads the host-selected machine configuration. A host without a
// configuration directory, or a machine with no saved document, stays local.
// Malformed saved configuration fails visibly and is never replaced.
func (c *Component) savedProfile(ctx context.Context) (machineconfig.HiveProfile, bool, error) {
	if c.options.ConfigDirectory == "" {
		return machineconfig.LocalHiveProfile(), false, nil
	}
	store, err := machineconfig.New(c.options.ConfigDirectory)
	if err != nil {
		return machineconfig.HiveProfile{}, false, err
	}
	document, err := store.Read(ctx)
	if errors.Is(err, os.ErrNotExist) {
		return machineconfig.LocalHiveProfile(), false, nil
	}
	if err != nil {
		return machineconfig.HiveProfile{}, false, err
	}
	return document.Hive, document.Hive.Mode == machineconfig.HiveModeJoined, nil
}

// localAlias selects the same-machine loopback address of the bind family a
// joined profile selected. A joined owner advertises a Hive-reachable address,
// so its local clients reach it through this alias instead.
func localAlias(bind string) (netip.Addr, error) {
	if bind == "" {
		return netip.MustParseAddr("127.0.0.1"), nil
	}
	address, err := netip.ParseAddr(bind)
	if err != nil || address.Zone() != "" {
		return netip.Addr{}, errors.New("joined Hive bind address must be a literal IP")
	}
	if address.Is6() {
		return netip.MustParseAddr("::1"), nil
	}
	return netip.MustParseAddr("127.0.0.1"), nil
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
	var descriptor rendezvous.Descriptor
	var err error
	if state.joined {
		descriptor, err = rendezvous.CaptureLocal(membership.LocalNode(), state.execution, state.gossip, state.transport)
	} else {
		descriptor, err = rendezvous.Capture(membership.LocalNode(), state.execution)
	}
	if err != nil {
		return err
	}
	if descriptor.Node != state.node || descriptor.PublicKey != state.publicKey {
		return errors.New("local owner native identity mismatch")
	}
	if !state.joined {
		for _, address := range []string{descriptor.Gossip, descriptor.Transport} {
			endpoint, err := netip.ParseAddrPort(address)
			if err != nil || !endpoint.Addr().IsLoopback() {
				return errors.New("local owner requires loopback endpoints")
			}
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
		if state.releaseBoot != nil {
			state.releaseBoot()
		}
	}
	return nil
}
