// SPDX-License-Identifier: MIT

// Package hive is Bee's native host: it prepares, before the runtime boots,
// the cluster configuration that joins every Bee node of this machine into
// the machine's hive once `bee hive init` created it. Everything after boot
// is Lua.
package hive

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/wippyai/runtime/api/boot"
	clusterapi "github.com/wippyai/runtime/api/cluster"
	"github.com/wippyai/runtime/api/event"
	app "github.com/wippyai/runtime/cmd/app"

	"github.com/wippyai/bee/native/hookpost"
)

const (
	hiveFile      = "hive.json"
	nodesDir      = "nodes"
	nodeFile      = "node.json"
	keySuffix     = ".pub"
	addressSuffix = ".addr"
)

// Hive is the machine-wide hive configuration created by `bee hive init`.
type Hive struct {
	Secret string `json:"secret"`
	// Machine names this machine in invites.
	Machine string `json:"machine,omitempty"`
	// Port is the gossip port the first node of this machine binds, so other
	// machines know where to dial.
	Port int `json:"port,omitempty"`
	// Advertise is the address other machines reach this machine at. It is
	// set once the machine joined another, or another joined it; until then
	// nodes listen on loopback only.
	Advertise string `json:"advertise,omitempty"`
	// Seeds are gossip addresses of nodes on other machines.
	Seeds []string `json:"seeds,omitempty"`
}

// Node is one folder's node identity, kept in its state directory.
type Node struct {
	Name string `json:"name"`
	Seed string `json:"seed"`
}

// hookCommand posts one harness hook event to the node's gateway.
const hookCommand = "hook-post"

// clientCommand is the application command an in-memory client node runs.
const clientCommand = "client"

// nodeCommand runs the folder's node without a display.
const nodeCommand = "node"

// RoleVariable tells the application what this process is. An in-memory
// client sets it to ClientRole: it displays another node and serves no node of
// its own.
const (
	RoleVariable = "BEE_ROLE"
	ClientRole   = "client"
)

// Host plans Bee launches and publishes the node's address once it runs.
type Host struct {
	dir  string
	node string
	// ephemeral marks an in-memory client node, whose key is withdrawn with
	// its address.
	ephemeral bool
	members   Members
	// watch restarts this bee when the machine's hive changes under it.
	watch *hiveWatch
	cache *remoteCache
	// relaunch replaces the process once it stopped for a restart.
	relaunch func() error
}

// Component returns the Bee native host.
func Component() *Host { return &Host{} }

// Name implements boot.Component.
func (h *Host) Name() string { return "bee.hive" }

// DependsOn implements boot.Component: the address exists once the cluster runs.
func (h *Host) DependsOn() []string { return []string{"cluster"} }

// Load implements boot.Component: the cluster created its membership, which
// resolves the keys of nodes on other machines.
func (h *Host) Load(ctx context.Context) (context.Context, error) {
	if membership := clusterapi.GetMembership(ctx); membership != nil {
		h.members.bind(membership)
	}
	return ctx, nil
}

// Start records this node's membership address so other nodes can join it.
func (h *Host) Start(ctx context.Context) error {
	if h.watch != nil {
		h.watch.start()
	}
	if h.node == "" {
		return nil
	}
	if bus := event.GetBus(ctx); bus != nil && h.cache == nil {
		cache, err := startRemoteCache(ctx, bus, h.dir)
		if err != nil {
			return err
		}
		h.cache = cache
	}
	membership := clusterapi.GetMembership(ctx)
	if membership == nil {
		return errors.New("bee hive: cluster membership is not running")
	}
	address := membership.LocalNode().Addr
	if address == "" {
		return errors.New("bee hive: membership has no local address")
	}
	return writeFile(filepath.Join(h.dir, nodesDir, h.node+addressSuffix), []byte(address))
}

// Stop withdraws this node's address, and a client node's key.
func (h *Host) Stop(context.Context) error {
	if h.watch != nil {
		h.watch.close()
	}
	if h.cache != nil {
		h.cache.close()
		h.cache = nil
	}
	if h.node == "" {
		return nil
	}
	err := removeFile(filepath.Join(h.dir, nodesDir, h.node+addressSuffix))
	if h.ephemeral {
		err = errors.Join(err, removeFile(filepath.Join(h.dir, nodesDir, h.node+keySuffix)))
	}
	return err
}

func removeFile(path string) error {
	err := os.Remove(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

// Plan implements app.Host.
func (h *Host) Plan(_ context.Context, launch app.Launch) (app.Plan, error) {
	// A harness hook process carries a token the gateway authorizes. It posts one
	// event within the hook deadline and never selects a folder, opens state or
	// reaches a node.
	if launch.Op == app.OpRun && len(launch.Args) > 0 && launch.Args[0] == hookCommand {
		if len(launch.Args) != 5 {
			return app.Plan{}, errors.New("bee hook-post: expected ENDPOINT ACTION_ID TOKEN_ENV_OR_FILE EVENT")
		}
		args := launch.Args
		return app.Plan{Run: func(ctx context.Context) error {
			return hookpost.RunTo(ctx, os.Stdin, os.Stdout, args[1], args[2], args[3], args[4])
		}}, nil
	}
	if launch.Op == app.OpRun && isHelp(launch.Args) {
		return app.Plan{Run: func(context.Context) error { Help(os.Stdout); return nil }}, nil
	}
	dir, err := Dir()
	if err != nil {
		return app.Plan{}, err
	}
	h.dir = dir
	if len(launch.Args) > 0 && launch.Args[0] == "hive" {
		switch {
		case len(launch.Args) == 2 && launch.Args[1] == "init":
			return app.Plan{Run: func(context.Context) error { return Init(dir) }}, nil
		case len(launch.Args) == 2 && launch.Args[1] == "invite":
			return app.Plan{Run: func(ctx context.Context) error { return Invite(ctx, dir, os.Stdout, os.Stderr) }}, nil
		case len(launch.Args) == 3 && launch.Args[1] == "join":
			token := launch.Args[2]
			return app.Plan{Run: func(ctx context.Context) error { return Join(ctx, dir, token, os.Stdout) }}, nil
		}
		return app.Plan{}, fmt.Errorf("bee hive: unknown command %q; available: bee hive init, bee hive invite, bee hive join TOKEN", strings.Join(launch.Args[1:], " "))
	}
	hive, err := ReadHive(dir)
	if err != nil {
		return app.Plan{}, err
	}
	explicit := len(launch.Args) == 1 && launch.Args[0] == clientCommand
	headless := len(launch.Args) == 1 && launch.Args[0] == nodeCommand
	owned := false
	if launch.Op == app.OpRun {
		if owned, err = app.Owned(launch.State); err != nil {
			return app.Plan{}, err
		}
	}
	if launch.Op == app.OpRun && len(launch.Args) > 0 && launch.Args[0] == "mcp" {
		name, err := mcpName(launch.Args)
		if err != nil {
			return app.Plan{}, err
		}
		if !owned {
			return app.Plan{}, errors.New("bee mcp connect: this folder needs a running node")
		}
		plan, err := h.clientPlan(dir, launch.State, hive, owned, nil)
		if err != nil {
			return app.Plan{}, err
		}
		plan.Command = "mcp"
		plan.Args = append(plan.Args, name)
		return plan, nil
	}
	if headless {
		if owned {
			return app.Plan{}, errors.New("bee node: a bee is already running in this folder")
		}
		plan := h.nodePlan(dir, launch.State, hive)
		plan.Command, plan.Args = nodeCommand, []string{}
		return plan, nil
	}
	// A bee started while this folder's node runs is a display of that
	// node; an app command it was given (bee claude) opens there.
	if explicit || owned {
		var command []string
		if !explicit {
			command = launch.Args
		}
		return h.clientPlan(dir, launch.State, hive, owned, command)
	}
	if hive == nil && launch.Op != app.OpRun {
		return app.Plan{}, nil
	}
	return h.nodePlan(dir, launch.State, hive), nil
}

// nodePlan runs the folder's node, joining the machine's hive when there is one.
func (h *Host) nodePlan(dir, state string, hive *Hive) app.Plan {
	return app.Plan{Prepare: func(context.Context) (boot.Config, func() error, error) {
		h.watchHive(dir, hive)
		if hive == nil {
			return boot.NewConfig(), h.finish, nil
		}
		config, node, err := Prepare(dir, state, *hive, &h.members)
		if err != nil {
			return nil, nil, err
		}
		h.node = node
		return config, h.finish, nil
	}}
}

// watchHive makes this bee restart when the machine's hive differs from applied.
func (h *Host) watchHive(dir string, applied *Hive) {
	h.watch = &hiveWatch{dir: dir, applied: applied, interval: pollInterval, interrupt: interruptSelf}
}

// finish runs after the bee stopped: a bee that stopped to adopt a changed hive
// starts again as the same command.
func (h *Host) finish() error {
	if h.watch == nil || !h.watch.restartRequested() {
		return nil
	}
	if h.relaunch == nil {
		return relaunch()
	}
	return h.relaunch()
}

// clientPlan runs an in-memory client node of the machine's hive. It displays
// the node running in this folder when there is one, opening the app command
// given, else a node of the hive; the display moves to any other node from its
// workspace menu.
func (h *Host) clientPlan(dir, state string, hive *Hive, owned bool, command []string) (app.Plan, error) {
	if hive == nil {
		if owned {
			return app.Plan{}, errors.New("bee is already running in this folder and is not in a hive; run bee hive init and restart it to open more displays")
		}
		return app.Plan{}, errors.New("bee client: this machine is in no hive; run bee hive init")
	}
	args := []string{}
	if owned {
		target, err := folderNode(state)
		if err != nil {
			return app.Plan{}, err
		}
		args = append([]string{target}, command...)
	}
	return app.Plan{
		Transient: true,
		Command:   clientCommand,
		Args:      args,
		Prepare: func(context.Context) (boot.Config, func() error, error) {
			if err := os.Setenv(RoleVariable, ClientRole); err != nil {
				return nil, nil, fmt.Errorf("bee client: set %s: %w", RoleVariable, err)
			}
			config, node, err := PrepareClient(dir, *hive, &h.members)
			if err != nil {
				return nil, nil, err
			}
			h.node, h.ephemeral = node, true
			h.watchHive(dir, hive)
			return config, h.finish, nil
		},
	}, nil
}

// folderNode names the hive node of the folder whose state is at state.
func folderNode(state string) (string, error) {
	data, err := os.ReadFile(filepath.Join(state, nodeFile))
	if errors.Is(err, os.ErrNotExist) {
		return "", errors.New("bee is already running in this folder and is not in a hive; run bee hive init and restart it to open more displays")
	}
	if err != nil {
		return "", err
	}
	var node Node
	if err := json.Unmarshal(data, &node); err != nil || node.Name == "" {
		return "", fmt.Errorf("%s is not a node identity", filepath.Join(state, nodeFile))
	}
	return node.Name, nil
}

// Dir is this machine's hive directory.
func Dir() (string, error) {
	config, err := os.UserConfigDir()
	if err != nil {
		return "", fmt.Errorf("bee hive: locate user configuration directory: %w", err)
	}
	return filepath.Join(config, "bee", "hive"), nil
}

// Init creates the machine's hive. An existing hive is kept.
func Init(dir string) error {
	existing, err := ReadHive(dir)
	if err != nil {
		return err
	}
	if existing != nil {
		fmt.Printf("Hive already initialized in %s\n", dir)
		return nil
	}
	if _, err := Ensure(dir); err != nil {
		return err
	}
	fmt.Printf("Hive initialized in %s\nEvery bee started on this machine now joins it.\n", dir)
	return nil
}

// Ensure returns the machine's hive, creating it when there is none and
// completing a record that lacks its machine name or gossip port.
func Ensure(dir string) (*Hive, error) {
	hive, err := ReadHive(dir)
	if err != nil {
		return nil, err
	}
	if hive == nil {
		secret := make([]byte, 32)
		if _, err := rand.Read(secret); err != nil {
			return nil, err
		}
		hive = &Hive{Secret: base64.StdEncoding.EncodeToString(secret)}
	}
	complete := hive.Machine != "" && hive.Port != 0
	if hive.Machine == "" {
		hive.Machine = randomHex(8)
	}
	if hive.Port == 0 {
		port, err := randomPort()
		if err != nil {
			return nil, err
		}
		hive.Port = port
	}
	if complete {
		return hive, nil
	}
	return hive, WriteHive(dir, *hive)
}

// WriteHive stores the machine's hive configuration.
func WriteHive(dir string, hive Hive) error {
	data, err := json.Marshal(hive)
	if err != nil {
		return err
	}
	return writeFile(filepath.Join(dir, hiveFile), data)
}

func randomHex(size int) string {
	data := make([]byte, size)
	if _, err := rand.Read(data); err != nil {
		panic(err)
	}
	return hex.EncodeToString(data)
}

// randomPort picks a gossip port below the operating system's ephemeral range.
func randomPort() (int, error) {
	value, err := rand.Int(rand.Reader, big.NewInt(20000))
	if err != nil {
		return 0, err
	}
	return 30000 + int(value.Int64()), nil
}

func appendUnique(list []string, value string) []string {
	if slices.Contains(list, value) {
		return list
	}
	return append(list, value)
}

// ReadHive returns the machine's hive, or nil when none was initialized.
func ReadHive(dir string) (*Hive, error) {
	data, err := os.ReadFile(filepath.Join(dir, hiveFile))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var hive Hive
	if err := json.Unmarshal(data, &hive); err != nil || hive.Secret == "" {
		return nil, fmt.Errorf("bee hive: %s is not a hive configuration", filepath.Join(dir, hiveFile))
	}
	return &hive, nil
}

// Prepare returns the boot configuration that joins this folder's node into
// the hive, and the node's name.
func Prepare(dir, state string, hive Hive, members *Members) (boot.Config, string, error) {
	node, key, err := loadNode(state)
	if err != nil {
		return nil, "", err
	}
	config, err := configure(dir, hive, node, key, members)
	return config, node.Name, err
}

// PrepareClient returns the boot configuration of an in-memory client node:
// a fresh identity that is never written to disk, joined into the hive.
func PrepareClient(dir string, hive Hive, members *Members) (boot.Config, string, error) {
	node, key, err := newNode("bee-client-")
	if err != nil {
		return nil, "", err
	}
	config, err := configure(dir, hive, node, key, members)
	return config, node.Name, err
}

// configure publishes node's public key and builds its cluster configuration.
func configure(dir string, hive Hive, node Node, key ed25519.PrivateKey, members *Members) (boot.Config, error) {
	public := base64.StdEncoding.EncodeToString(key.Public().(ed25519.PublicKey))
	if err := writeFile(filepath.Join(dir, nodesDir, node.Name+keySuffix), []byte(public)); err != nil {
		return nil, err
	}
	joins, err := peerAddresses(dir, node.Name)
	if err != nil {
		return nil, err
	}
	for _, seed := range append(slices.Clone(hive.Seeds), remoteAddresses(dir)...) {
		joins = appendUnique(joins, seed)
	}
	cluster := map[string]any{
		"enabled":                true,
		"name":                   node.Name,
		"raft.enabled":           false,
		"membership.bind_addr":   "127.0.0.1",
		"membership.bind_port":   0,
		"membership.join_addrs":  strings.Join(joins, ","),
		"membership.secret_key":  hive.Secret,
		"internode.bind_addr":    "127.0.0.1",
		"internode.identity_key": node.Seed,
		"internode.peer_key_source": clusterapi.PeerKeySource(func(id clusterapi.NodeID) (ed25519.PublicKey, bool) {
			if key, ok := peerKey(dir, string(id)); ok {
				return key, true
			}
			if hive.Advertise == "" {
				return nil, false
			}
			return members.advertisedKey(string(id))
		}),
		"internode.trusted_peer_keys." + node.Name: public,
	}
	if hive.Advertise != "" {
		cluster["membership.bind_addr"] = "0.0.0.0"
		cluster["membership.advertise_addr"] = hive.Advertise
		cluster["membership.bind_port"] = claimGossipPort(dir, hive.Port)
		cluster["internode.bind_addr"] = "0.0.0.0"
	}
	return boot.NewConfig(
		boot.WithSection("relay", map[string]any{"node_name": node.Name}),
		boot.WithSection("cluster", cluster),
	), nil
}

// newNode generates a node identity named with prefix.
func newNode(prefix string) (Node, ed25519.PrivateKey, error) {
	seed := make([]byte, ed25519.SeedSize)
	if _, err := rand.Read(seed); err != nil {
		return Node{}, nil, err
	}
	name := make([]byte, 16)
	if _, err := rand.Read(name); err != nil {
		return Node{}, nil, err
	}
	node := Node{Name: fmt.Sprintf("%s%x", prefix, name), Seed: base64.StdEncoding.EncodeToString(seed)}
	return node, ed25519.NewKeyFromSeed(seed), nil
}

// loadNode reads this folder's node identity, creating it on first use.
func loadNode(state string) (Node, ed25519.PrivateKey, error) {
	path := filepath.Join(state, nodeFile)
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		node, key, err := newNode("bee-")
		if err != nil {
			return Node{}, nil, err
		}
		encoded, err := json.Marshal(node)
		if err != nil {
			return Node{}, nil, err
		}
		if err := writeFile(path, encoded); err != nil {
			return Node{}, nil, err
		}
		return node, key, nil
	}
	if err != nil {
		return Node{}, nil, err
	}
	var node Node
	if err := json.Unmarshal(data, &node); err != nil || node.Name == "" {
		return Node{}, nil, fmt.Errorf("bee hive: %s is not a node identity", path)
	}
	seed, err := base64.StdEncoding.DecodeString(node.Seed)
	if err != nil || len(seed) != ed25519.SeedSize {
		return Node{}, nil, fmt.Errorf("bee hive: %s holds an invalid node key", path)
	}
	return node, ed25519.NewKeyFromSeed(seed), nil
}

// peerAddresses lists the membership addresses other nodes recorded.
func peerAddresses(dir, self string) ([]string, error) {
	entries, err := os.ReadDir(filepath.Join(dir, nodesDir))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var addresses []string
	for _, entry := range entries {
		name, ok := strings.CutSuffix(entry.Name(), addressSuffix)
		if !ok || name == self {
			continue
		}
		data, err := os.ReadFile(filepath.Join(dir, nodesDir, entry.Name()))
		if err != nil {
			continue
		}
		if address := strings.TrimSpace(string(data)); address != "" {
			addresses = append(addresses, address)
		}
	}
	return addresses, nil
}

// peerKey resolves a hive node's public key from its published key file.
func peerKey(dir, node string) (ed25519.PublicKey, bool) {
	if node == "" || strings.ContainsAny(node, `/\`) || strings.Contains(node, "..") {
		return nil, false
	}
	data, err := os.ReadFile(filepath.Join(dir, nodesDir, node+keySuffix))
	if err != nil {
		return nil, false
	}
	key, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(data)))
	if err != nil || len(key) != ed25519.PublicKeySize {
		return nil, false
	}
	return ed25519.PublicKey(key), true
}

// writeFile replaces path atomically with owner-only permissions.
func writeFile(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	pending, err := os.CreateTemp(filepath.Dir(path), ".pending-")
	if err != nil {
		return err
	}
	if _, err := pending.Write(data); err != nil {
		_ = pending.Close()
		_ = os.Remove(pending.Name())
		return err
	}
	if err := pending.Chmod(0o600); err != nil {
		_ = pending.Close()
		_ = os.Remove(pending.Name())
		return err
	}
	if err := pending.Close(); err != nil {
		_ = os.Remove(pending.Name())
		return err
	}
	return os.Rename(pending.Name(), path)
}
