// SPDX-License-Identifier: MIT

package launch

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/wippyai/bee/native/hive/invite"
	"github.com/wippyai/bee/native/hive/meshtls"
	"github.com/wippyai/bee/native/internal/privatefile"
	clusterapi "github.com/wippyai/runtime/api/cluster"
	"github.com/wippyai/runtime/cluster/internode"
)

const (
	// ownerLockName is held by the owner for its whole lifetime and by a hive
	// join while it rewrites the mesh the next owner boots with, so the two
	// never overlap.
	ownerLockName = "owner.lock"
	// joinedRecordName marks a node that joined another node's hive: it names
	// the hive node, the gossip seed and the hive's authority pool. The mesh
	// secret and the certified leaf the hive node issued sit beside it.
	joinedRecordName     = "joined.json"
	joinedSecretName     = "joined.secret"
	joinedCredentialName = "joined.pem"
	maxJoinedRecordBytes = meshtls.MaxBytes + 1024
	// gossipPortName keeps the gossip port the node's first boot selected. Later
	// boots bind it again, so the address the node's hive remembers stays valid
	// across restarts, clean or not.
	gossipPortName = "gossip.port"
	// peerAddressSuffix names a pinned peer's last gossip address, beside its
	// key in the peers directory; the next boot seeds it.
	peerAddressSuffix = ".addr"
)

// meshAddress is the default owner address. A host can explicitly select an
// assigned address for a Hive reachable from another machine.
var meshAddress = netip.MustParseAddr("127.0.0.1")

func selectedMeshAddress() (netip.Addr, error) {
	value := os.Getenv("BEE_MESH_ADDRESS")
	if value == "" {
		return meshAddress, nil
	}
	address, err := netip.ParseAddr(value)
	if err != nil || address.Zone() != "" || !address.IsGlobalUnicast() || address.IsLoopback() {
		return netip.Addr{}, errors.New("BEE_MESH_ADDRESS must be an assigned external IP address")
	}
	interfaces, err := net.InterfaceAddrs()
	if err != nil {
		return netip.Addr{}, err
	}
	for _, entry := range interfaces {
		if network, ok := entry.(*net.IPNet); ok {
			if assigned, ok := netip.AddrFromSlice(network.IP); ok && assigned.Unmap() == address.Unmap() {
				return address.Unmap(), nil
			}
		}
	}
	return netip.Addr{}, errors.New("BEE_MESH_ADDRESS is not assigned to this host")
}

func meshBindAddress(address netip.Addr) netip.Addr {
	if address.IsLoopback() {
		return address
	}
	if address.Is4() {
		return netip.IPv4Unspecified()
	}
	return netip.IPv6Unspecified()
}

// joinedRecord is the persisted outcome of a hive join.
type joinedRecord struct {
	Node        string `json:"node"`
	Gossip      string `json:"gossip"`
	Authorities string `json:"authorities"`
	JoinPath    string `json:"join_path,omitempty"`
}

// gossipSeedForPath uses the authenticated TCP route's peer IP with the
// runtime gossip port. This handles an alternate interface or a forwarded
// host address during the initial join, without trusting an unverified hint.
func gossipSeedForPath(gossip netip.AddrPort, verifiedPath string) netip.AddrPort {
	path, err := netip.ParseAddrPort(verifiedPath)
	if err != nil || path.Addr().IsLoopback() || path.Addr().IsUnspecified() {
		return gossip
	}
	return netip.AddrPortFrom(path.Addr(), gossip.Port())
}

// lockOwner takes the owner lock of state, refusing while another owner runs
// or a hive join rewrites the mesh.
func lockOwner(ctx context.Context, state string) (func() error, error) {
	directory := ownerDirectory(state)
	if err := privatefile.EnsurePrivateDir(directory); err != nil {
		return nil, err
	}
	unlock, err := privatefile.TryLock(ctx, directory, ownerLockName)
	if errors.Is(err, privatefile.ErrLockBusy) {
		return nil, errOwnerRunning
	}
	return unlock, err
}

var errOwnerRunning = errors.New("this Bee is running")

// readJoined returns the joined record of state, if the node joined a hive.
func readJoined(state string) (joinedRecord, bool, error) {
	data, err := os.ReadFile(filepath.Join(ownerDirectory(state), joinedRecordName))
	if errors.Is(err, os.ErrNotExist) {
		return joinedRecord{}, false, nil
	}
	if err != nil {
		return joinedRecord{}, false, err
	}
	var record joinedRecord
	if len(data) > maxJoinedRecordBytes || strictJSON(data, &record) != nil || !invite.ValidNode(record.Node) {
		return joinedRecord{}, false, errors.New("joined hive record is invalid")
	}
	if _, err := netip.ParseAddrPort(record.Gossip); err != nil {
		return joinedRecord{}, false, errors.New("joined hive record is invalid")
	}
	if record.JoinPath != "" {
		path, err := netip.ParseAddrPort(record.JoinPath)
		if err != nil || path.Port() == 0 || path.Addr().IsUnspecified() {
			return joinedRecord{}, false, errors.New("joined hive record is invalid")
		}
	}
	if _, err := meshtls.Authorities([]byte(record.Authorities)); err != nil {
		return joinedRecord{}, false, errors.New("joined hive record is invalid")
	}
	return record, true, nil
}

func strictJSON(data []byte, into any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	return decoder.Decode(into)
}

// membershipSecretPath is the secret the owner's mesh uses: the hive's secret
// once the node joined one, else its own.
func membershipSecretPath(state string) (string, error) {
	_, joined, err := readJoined(state)
	if err != nil {
		return "", err
	}
	if joined {
		return filepath.Join(ownerDirectory(state), joinedSecretName), nil
	}
	return filepath.Join(ownerDirectory(state), membershipSecretName), nil
}

// ensureAuthority returns the node's own mesh authority, creating it once.
func ensureAuthority(directory string, now time.Time) (meshtls.Authority, error) {
	path := filepath.Join(directory, meshtls.AuthorityFile)
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		if data, err = meshtls.NewAuthority(now); err != nil {
			return meshtls.Authority{}, err
		}
		if err := writeOwnerFile(path, data); err != nil {
			return meshtls.Authority{}, err
		}
	} else if err != nil {
		return meshtls.Authority{}, err
	}
	return meshtls.DecodeAuthority(data, now)
}

// meshBoot is what one owner boot's mesh uses.
type meshBoot struct {
	secret string
	seeds  string
	port   int
}

// prepareMesh writes the credential and authority pool the owner's mesh uses
// in this boot and returns its secret file, gossip seeds and gossip port. A
// joined node uses the leaf its hive node certified and trusts that hive's
// pool beside its own authority; any other node certifies a fresh leaf with
// its own authority. The seeds are the joined hive node and every pinned
// peer's last known address.
func prepareMesh(state string, now time.Time, address netip.Addr) (meshBoot, error) {
	directory := ownerDirectory(state)
	authority, err := ensureAuthority(directory, now)
	if err != nil {
		return meshBoot{}, err
	}
	record, joined, err := readJoined(state)
	if err != nil {
		return meshBoot{}, err
	}
	port, err := readGossipPort(directory)
	if err != nil {
		return meshBoot{}, err
	}
	seeds, err := peerAddresses(state)
	if err != nil {
		return meshBoot{}, err
	}
	var credential, pool []byte
	secret := filepath.Join(directory, membershipSecretName)
	if joined {
		if credential, err = os.ReadFile(filepath.Join(directory, joinedCredentialName)); err != nil {
			return meshBoot{}, fmt.Errorf("joined hive credential: %w", err)
		}
		if pool, err = meshtls.Pool(authority.Certificate(), []byte(record.Authorities)); err != nil {
			return meshBoot{}, err
		}
		secret = filepath.Join(directory, joinedSecretName)
		if !slices.Contains(seeds, record.Gossip) {
			seeds = append([]string{record.Gossip}, seeds...)
		}
	} else {
		public, private, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			return meshBoot{}, err
		}
		addresses, err := selectedMeshCertificateAddresses(address)
		if err != nil {
			return meshBoot{}, err
		}
		leaf, err := authority.Issue(public, addresses, now)
		if err != nil {
			return meshBoot{}, err
		}
		if credential, err = meshtls.Credential(leaf, private); err != nil {
			return meshBoot{}, err
		}
		if pool, err = meshtls.Pool(authority.Certificate()); err != nil {
			return meshBoot{}, err
		}
	}
	if err := writeOwnerFile(filepath.Join(directory, meshtls.CredentialFile), credential); err != nil {
		return meshBoot{}, err
	}
	if err := writeOwnerFile(filepath.Join(directory, meshtls.AuthoritiesFile), pool); err != nil {
		return meshBoot{}, err
	}
	return meshBoot{secret: secret, seeds: strings.Join(seeds, ","), port: port}, nil
}

// readGossipPort returns the port a previous boot selected, or zero before
// the first boot publishes one.
func readGossipPort(directory string) (int, error) {
	data, err := os.ReadFile(filepath.Join(directory, gossipPortName))
	if errors.Is(err, os.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	port, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil || port < 1 || port > 65535 {
		return 0, errors.New("recorded gossip port is invalid")
	}
	return port, nil
}

// peerAddresses returns the last known gossip address of every pinned peer, in
// node order.
func peerAddresses(state string) ([]string, error) {
	peers, err := trustedKeys(ownerPeersDirectory(state))
	if err != nil {
		return nil, err
	}
	var result []string
	for _, peer := range peers {
		data, err := os.ReadFile(filepath.Join(ownerPeersDirectory(state), peer.node+peerAddressSuffix))
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		address, err := netip.ParseAddrPort(strings.TrimSpace(string(data)))
		if err != nil || address.Port() == 0 {
			return nil, fmt.Errorf("recorded address of %s is invalid", peer.node)
		}
		result = append(result, address.String())
	}
	return result, nil
}

// recordAddresses keeps the hive's addresses stable across owner boots: the
// node's own gossip port, which the next boot binds again, and the gossip
// address of each pinned peer that is a member under its pinned key, which the
// next boot seeds.
func recordAddresses(state string, membership clusterapi.Membership) error {
	directory := ownerDirectory(state)
	local, err := netip.ParseAddrPort(membership.LocalNode().Addr)
	if err != nil {
		return fmt.Errorf("local gossip address: %w", err)
	}
	if err := writeChanged(filepath.Join(directory, gossipPortName), strconv.Itoa(int(local.Port()))); err != nil {
		return err
	}
	peers, err := trustedKeys(ownerPeersDirectory(state))
	if err != nil {
		return err
	}
	pinned := make(map[string]ed25519.PublicKey, len(peers))
	for _, peer := range peers {
		pinned[peer.node] = peer.key
	}
	for _, member := range membership.Nodes() {
		key, ok := pinned[member.ID]
		if !ok || member.Meta[internode.MetadataPublicKey] != base64.RawStdEncoding.EncodeToString(key) {
			continue
		}
		address, err := netip.ParseAddrPort(member.Addr)
		if err != nil || address.Port() == 0 {
			continue
		}
		if err := writeChanged(filepath.Join(ownerPeersDirectory(state), member.ID+peerAddressSuffix), address.String()); err != nil {
			return err
		}
	}
	return nil
}

// writeChanged writes value as one line unless the file already holds it.
func writeChanged(path, value string) error {
	if existing, err := os.ReadFile(path); err == nil && strings.TrimSpace(string(existing)) == value {
		return nil
	}
	return writeOwnerFile(path, []byte(value+"\n"))
}
