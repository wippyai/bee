// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/wippyai/bee/native/hive/invite"
	"github.com/wippyai/bee/native/hive/meshtls"
	"github.com/wippyai/bee/native/hive/rendezvous"
	"github.com/wippyai/bee/native/internal/privatefile"
	"github.com/wippyai/bee/native/internal/timewire"
	"github.com/wippyai/runtime/api/boot"
	clusterapi "github.com/wippyai/runtime/api/cluster"
)

const (
	// ownerDirectoryName is the owner-owned subdirectory under the state
	// directory holding the membership secret, the internode identity and the
	// client enrollment material.
	ownerDirectoryName = "hive"
	// trustedDirectoryName holds the public keys of enrolled local client nodes,
	// each kept only while its client holds the liveness lock beside it.
	trustedDirectoryName = "trusted"
	// peersDirectoryName holds the pinned identity keys of this node's Hive
	// peers. A pin stays until the peer is retired. internode.peer_key_source
	// reads this directory and the trusted one.
	peersDirectoryName   = "peers"
	membershipSecretName = "membership.secret"
	internodeKeyName     = "internode.key"
)

// ownerComponents returns the boot components the owner route adds: the
// rendezvous publisher that advertises this owner's live join address for local
// clients, the join listener that redeems Hive invites, and the enrollment
// publisher that mirrors the trusted client and peer directories into the
// supervisor's admission entry.
func ownerComponents(state, execution, launch string) ([]boot.Component, error) {
	address, err := selectedMeshAddress(state)
	if err != nil {
		return nil, err
	}
	directory := filepath.Join(state, rendezvous.DirectoryName)
	rendezvousPublisher, err := rendezvous.Publisher(directory, execution, launch, !address.IsLoopback())
	if err != nil {
		return nil, err
	}
	listener, err := joinListener(state, address)
	if err != nil {
		return nil, err
	}
	publisher, err := enrollmentPublisher(state)
	if err != nil {
		return nil, err
	}
	return []boot.Component{rendezvousPublisher, listener, publisher}, nil
}

// prepareOwner opens the owner's retained host resources. The runtime calls it
// as the host's Plan.Prepare under the real application state lock, so it runs
// once per owner boot and its release runs after shutdown while that lock is
// still held. It never mutates an existing credential: a secret or identity
// already on disk is reused byte-for-byte. folder selects whether the desktop
// bridge composes the folder's own workspace (bee start) or serves only the
// node's catalog workspaces (bee daemon).
func prepareOwner(state string, folder bool) (boot.Config, func() error, error) {
	projectDir, err := os.Getwd()
	if err != nil {
		return nil, nil, fmt.Errorf("resolve owner project directory: %w", err)
	}
	return prepareOwnerForProject(state, projectDir, folder)
}

func prepareOwnerForProject(state, projectDir string, folder bool) (boot.Config, func() error, error) {
	if state == "" || !filepath.IsAbs(state) {
		return nil, nil, errors.New("owner preparation requires an absolute state directory")
	}
	directory := ownerDirectory(state)
	if err := privatefile.EnsurePrivateDir(directory); err != nil {
		return nil, nil, err
	}
	unlock, err := lockOwner(context.Background(), state)
	if err != nil {
		return nil, nil, err
	}
	identity, identityUnlock, err := ensureStateNodeIdentity(context.Background(), state, projectDir)
	if err != nil {
		return nil, nil, errors.Join(err, unlock())
	}
	config, err := prepareLockedOwner(state, identity.NodeID, folder)
	if err != nil {
		return nil, nil, errors.Join(err, identityUnlock(), unlock())
	}
	return config, func() error { return errors.Join(identityUnlock(), unlock()) }, nil
}

// prepareLockedOwner builds the owner's boot configuration while it holds the
// owner lock.
func prepareLockedOwner(state, node string, folder bool) (boot.Config, error) {
	address, err := selectedMeshAddress(state)
	if err != nil {
		return nil, err
	}
	directory := ownerDirectory(state)
	trustedPath := ownerTrustedDirectory(state)
	if err := privatefile.EnsurePrivateDir(trustedPath); err != nil {
		return nil, err
	}
	if _, err := ensureSecretFile(filepath.Join(directory, membershipSecretName), 32); err != nil {
		return nil, err
	}
	keyPath := filepath.Join(directory, internodeKeyName)
	private, _, err := ensureIdentityFile(keyPath)
	if err != nil {
		return nil, err
	}
	public := private.Public().(ed25519.PublicKey)

	execution, err := beginExecution(directory)
	if err != nil {
		return nil, err
	}
	mesh, err := prepareMesh(state, time.Now(), address)
	if err != nil {
		return nil, err
	}
	transport := meshtls.Config(directory)

	peersPath := ownerPeersDirectory(state)
	if err := privatefile.EnsurePrivateDir(peersPath); err != nil {
		return nil, err
	}
	allowedPeers, err := selectedDesktopPeers(state)
	if err != nil {
		return nil, err
	}
	peerSource := clusterapi.PeerKeySource(func(nodeID string) (ed25519.PublicKey, bool) {
		if key, ok := resolveTrustedKey(trustedPath, nodeID); ok {
			return key, true
		}
		return resolveTrustedKey(peersPath, nodeID)
	})
	cluster := map[string]any{
		"enabled":                             true,
		"name":                                node,
		"raft.enabled":                        false,
		"raft.role":                           "client",
		"membership.bind_addr":                meshBindAddress(address).String(),
		"membership.bind_port":                mesh.port,
		"membership.advertise_addr":           address.String(),
		"membership.join_addrs":               mesh.seeds,
		"membership.secret_file":              mesh.secret,
		"membership.secret_key":               "",
		"internode.bind_addr":                 meshBindAddress(address).String(),
		"internode.bind_port":                 0,
		"internode.auto_port":                 true,
		"internode.identity_key_file":         keyPath,
		"internode.identity_key":              "",
		"internode.trusted_peer_keys." + node: base64.RawStdEncoding.EncodeToString(public),
		"internode.peer_key_source":           peerSource,
		"internode.tls.enabled":               transport.Enabled,
		"internode.tls.cert_file":             transport.CertFile,
		"internode.tls.key_file":              transport.KeyFile,
		"internode.tls.ca_file":               transport.CAFile,
	}
	desktop := map[string]any{
		"execution":     execution,
		"expires_at":    ownerExpiry(),
		"allowed_nodes": []any{},
		"local_clients": true,
		"folder":        folder,
	}
	if len(allowedPeers) > 0 {
		desktop["allowed_peers"] = allowedPeers
	}
	// The supervisor service takes one input object. The override key is
	// namespace:entry:path, and the entry declares its input as a list, so the
	// whole input is replaced with the owner-selected configuration.
	supervisorInput := []any{map[string]any{
		"configured_nodes": []any{},
		"desktop":          desktop,
	}}
	return boot.NewConfig(
		boot.WithSection("relay", map[string]any{"node_name": node}),
		boot.WithSection("cluster", cluster),
		boot.WithSection("override", map[string]any{
			"bee.hive.service:supervisor_service:input": supervisorInput,
		}),
	), nil
}

// selectedDesktopPeers grants this node's desktop to every pinned Hive peer by
// default: joining a hive is the whole selection, so no environment variable
// and no restart is needed. The supervisor still requires a live peer
// enrollment before admitting a client, so `bee hive leave NODE` revokes the
// grant by retiring the pin.
func selectedDesktopPeers(state string) ([]any, error) {
	peers, err := trustedKeys(ownerPeersDirectory(state))
	if err != nil {
		return nil, err
	}
	allowed := make([]any, 0, len(peers))
	for _, peer := range peers {
		if !invite.ValidNode(peer.node) || peer.node == ownerNodeName(state) {
			continue
		}
		allowed = append(allowed, peer.node)
	}
	return allowed, nil
}

// ownerExpiry is the desktop-configuration expiry. The owner admits local
// clients for the retained lifetime; the value is a canonical UTC timestamp
// with millisecond precision, the only format the desktop bridge accepts.
func ownerExpiry() string {
	now := time.Now().UTC().Add(30 * 24 * time.Hour)
	return timewire.FormatCanonicalUTC(now)
}

// executionName retains this boot's owner incarnation between plan preparation
// and component startup. The next owner boot replaces it before publishing.
const executionName = "execution"

// beginExecution selects a fresh incarnation for one owner boot. The native
// rendezvous publisher and the desktop bridge both read this value.
func beginExecution(directory string) (string, error) {
	if err := privatefile.EnsurePrivateDir(directory); err != nil {
		return "", err
	}
	path := filepath.Join(directory, executionName)
	value, err := randomExecution()
	if err != nil {
		return "", err
	}
	if err := writeOwnerFile(path, []byte(value+"\n")); err != nil {
		return "", err
	}
	return value, nil
}

// ownerDirectory is the owner-owned state subdirectory, and ownerTrustedDirectory
// is the client-key directory internode.peer_key_source reads. The client
// preparation writes its own public key into the same directory.
func ownerDirectory(state string) string {
	return filepath.Join(state, ownerDirectoryName)
}

func ownerTrustedDirectory(state string) string {
	return filepath.Join(ownerDirectory(state), trustedDirectoryName)
}

func ownerPeersDirectory(state string) string {
	return filepath.Join(ownerDirectory(state), peersDirectoryName)
}

// ownerNodeName reads the state's persisted identity, falling back to the
// pre-persistence derivation for read-only routes that have not opened state.
func ownerNodeName(state string) string {
	identity, err := readStoredNodeIdentity(state)
	if err == nil {
		return identity.NodeID
	}
	return ownerNodeNameFromState(state)
}

func randomExecution() (string, error) {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(value[:]), nil
}

// ensureSecretFile creates a random base64 secret at path if absent and returns
// the path. An existing secret is validated and reused, never rewritten.
func ensureSecretFile(path string, size int) (string, error) {
	if size < 1 || size > 1<<20 {
		return "", errors.New("owner membership secret size is invalid")
	}
	encodedLimit := base64.StdEncoding.EncodedLen(size) + 2
	data, err := readOwnerFile(path, int64(encodedLimit))
	if err == nil {
		decoded, decodeErr := base64.StdEncoding.DecodeString(strings.TrimSpace(string(data)))
		if decodeErr != nil {
			return "", fmt.Errorf("owner membership secret is not base64: %w", decodeErr)
		}
		if len(decoded) != size {
			return "", errors.New("owner membership secret has an invalid length")
		}
		return path, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	secret := make([]byte, size)
	if _, err := rand.Read(secret); err != nil {
		return "", err
	}
	if err := writeOwnerFile(path, []byte(base64.StdEncoding.EncodeToString(secret)+"\n")); err != nil {
		return "", err
	}
	return path, nil
}

// ensureIdentityFile creates an Ed25519 identity at path if absent and returns
// the private and public keys. An existing identity is reused.
func ensureIdentityFile(path string) (ed25519.PrivateKey, ed25519.PublicKey, error) {
	if data, err := os.ReadFile(path); err == nil {
		private, decodeErr := decodeIdentity(strings.TrimSpace(string(data)))
		if decodeErr != nil {
			return nil, nil, decodeErr
		}
		return private, private.Public().(ed25519.PublicKey), nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, nil, err
	}
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	encoded := base64.StdEncoding.EncodeToString(private.Seed())
	if err := writeOwnerFile(path, []byte(encoded+"\n")); err != nil {
		return nil, nil, err
	}
	return private, public, nil
}

func decodeIdentity(encoded string) (ed25519.PrivateKey, error) {
	decoded, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		decoded, err = base64.RawStdEncoding.DecodeString(encoded)
	}
	if err != nil {
		return nil, fmt.Errorf("decode owner internode identity: %w", err)
	}
	switch len(decoded) {
	case ed25519.SeedSize:
		return ed25519.NewKeyFromSeed(decoded), nil
	case ed25519.PrivateKeySize:
		return append(ed25519.PrivateKey(nil), decoded...), nil
	default:
		return nil, errors.New("owner internode identity has an invalid length")
	}
}

// resolveTrustedKey reads one public key from a key directory (trusted clients
// or pinned peers). The filename is the node id; the content is base64. A
// missing or malformed file refuses the node.
func resolveTrustedKey(trustedPath, nodeID string) (ed25519.PublicKey, bool) {
	if !validTrustedName(nodeID) {
		return nil, false
	}
	data, err := os.ReadFile(filepath.Join(trustedPath, nodeID+".pub"))
	if err != nil {
		return nil, false
	}
	encoded := strings.TrimSpace(string(data))
	decoded, err := base64.RawStdEncoding.DecodeString(encoded)
	if err != nil {
		decoded, err = base64.StdEncoding.DecodeString(encoded)
	}
	if err != nil || len(decoded) != ed25519.PublicKeySize {
		return nil, false
	}
	return ed25519.PublicKey(decoded), true
}

func validTrustedName(nodeID string) bool {
	if nodeID == "" || len(nodeID) > 160 {
		return false
	}
	return !strings.ContainsAny(nodeID, `/\`) && !strings.Contains(nodeID, "..") && !strings.ContainsRune(nodeID, 0)
}

// writeOwnerFile replaces path atomically with an owner-only file.
func writeOwnerFile(path string, data []byte) error { return privatefile.WriteAtomic(path, data) }

func readOwnerFile(path string, maxBytes int64) ([]byte, error) {
	name := filepath.Base(path)
	file, err := privatefile.New(filepath.Dir(path), name, "."+name+".lock")
	if err != nil {
		return nil, err
	}
	return file.Read(context.Background(), maxBytes)
}

func sha256Hex(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}
