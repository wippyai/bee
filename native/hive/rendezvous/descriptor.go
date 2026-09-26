// SPDX-License-Identifier: MIT

// Package rendezvous publishes native mesh discovery hints for a running Bee.
// A descriptor does not grant cluster membership or desktop access.
package rendezvous

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/netip"
	"strconv"
	"unicode/utf8"

	"github.com/wippyai/runtime/api/cluster"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/cluster/internode"
)

const MaxBytes = 4096

// ClientRevision is the local client protocol this owner can answer. An absent
// value identifies a descriptor published before owners advertised this bound.
const ClientRevision = "bee.hive@1"

var ErrDescriptor = errors.New("invalid Bee mesh rendezvous descriptor")

// Descriptor contains public discovery data only. Execution identifies one
// owner invocation; reconnect must verify a live owner and request fresh grants.
type Descriptor struct {
	Version        int    `json:"version"`
	Execution      string `json:"execution"`
	Node           string `json:"node"`
	Gossip         string `json:"gossip"`
	Transport      string `json:"transport"`
	PublicKey      string `json:"public_key"`
	ClientRevision string `json:"client_revision,omitempty"`
	// Supervisor is the owner's Hive supervisor process address
	// ({node@bee.hive.service:supervisor_host|uniq}). A raft-disabled owner never
	// publishes the cluster-wide name, so a local client addresses the
	// supervisor directly. It is a hint: the client still verifies node, host
	// and identity and the supervisor authenticates the sender.
	Supervisor string `json:"supervisor,omitempty"`
	// Join is the owner's invite listener, where a node redeems an invite to
	// join this node's hive. It is bound on the mesh advertise address with an
	// automatically selected port.
	Join string `json:"join,omitempty"`
	// Launch is the identity the starting client handed this owner, 32
	// lowercase hexadecimal characters, or empty for an owner started by hand.
	// It lets that client prove its own start request won the state election.
	Launch string `json:"launch,omitempty"`
}

// Endpoint is the owner identity the live membership record authenticates:
// the descriptor without the supervisor, join and launch hints, which
// membership never carries.
func (d Descriptor) Endpoint() Descriptor {
	d.Supervisor = ""
	d.Join = ""
	d.Launch = ""
	d.ClientRevision = ""
	return d
}

// LaunchIdentity reports whether value is a well-formed launch identity.
func LaunchIdentity(value string) bool {
	if len(value) != 32 {
		return false
	}
	for _, r := range value {
		if (r < '0' || r > '9') && (r < 'a' || r > 'f') {
			return false
		}
	}
	return true
}

func (d Descriptor) validate() error {
	if d.Version != 1 || len(d.Execution) != 32 || len(d.Node) == 0 || len(d.Node) > 128 {
		return ErrDescriptor
	}
	if _, err := hex.DecodeString(d.Execution); err != nil {
		return ErrDescriptor
	}
	if len(d.ClientRevision) > 64 {
		return ErrDescriptor
	}
	for _, r := range d.ClientRevision {
		if r < 33 || r > 126 {
			return ErrDescriptor
		}
	}
	for _, r := range d.Node {
		if r < 33 || r > 126 {
			return ErrDescriptor
		}
	}
	for _, value := range []string{d.Gossip, d.Transport} {
		address, err := netip.ParseAddrPort(value)
		if err != nil || address.Port() == 0 || address.Addr().Zone() != "" || !address.Addr().IsGlobalUnicast() && !address.Addr().IsLoopback() {
			return ErrDescriptor
		}
	}
	key, err := base64.RawStdEncoding.DecodeString(d.PublicKey)
	if err != nil || len(key) != ed25519.PublicKeySize || base64.RawStdEncoding.EncodeToString(key) != d.PublicKey {
		return ErrDescriptor
	}
	if d.Join != "" {
		address, err := netip.ParseAddrPort(d.Join)
		if err != nil || address.Port() == 0 || address.Addr().Zone() != "" || !address.Addr().IsGlobalUnicast() && !address.Addr().IsLoopback() {
			return ErrDescriptor
		}
	}
	if d.Launch != "" && !LaunchIdentity(d.Launch) {
		return ErrDescriptor
	}
	if d.Supervisor != "" {
		address, err := pid.ParsePID(d.Supervisor)
		if err != nil || address.Node != d.Node || address.Host != "bee.hive.service:supervisor_host" || address.UniqID == "" {
			return ErrDescriptor
		}
	}
	return nil
}

// Capture builds a descriptor from the local membership snapshot after native
// cluster startup. Callers must hold the application-state lock and publish only
// their own live node. This function cannot infer socket ownership from values.
// The transport endpoint is the member's own membership address with its
// internode port: the runtime dials a member at its membership address and a
// one-way reachable member dials in itself, so there is no separate advertise
// address. Literal IP endpoints are required; DNS-only advertisements are not
// supported.
func Capture(node cluster.NodeInfo, execution string) (Descriptor, error) {
	gossip, err := netip.ParseAddrPort(node.Addr)
	if err != nil {
		return Descriptor{}, ErrDescriptor
	}
	port, err := strconv.ParseUint(node.Meta[internode.MetadataPort], 10, 16)
	if err != nil || port == 0 {
		return Descriptor{}, ErrDescriptor
	}
	d := Descriptor{Version: 1, Execution: execution, Node: node.ID, Gossip: gossip.String(),
		Transport: netip.AddrPortFrom(gossip.Addr(), uint16(port)).String(), PublicKey: node.Meta[internode.MetadataPublicKey]}
	if err := d.validate(); err != nil {
		return Descriptor{}, err
	}
	return d, nil
}

// CaptureLocal publishes same-machine aliases for a node whose mesh advertises
// a different reachable address to the Hive. The listener must be bound on the
// selected loopback family; this function only describes its already-bound
// gossip and internode ports. The caller still owns listener verification.
func CaptureLocal(node cluster.NodeInfo, execution string, gossipLoopback, transportLoopback netip.Addr) (Descriptor, error) {
	if !gossipLoopback.IsValid() || !gossipLoopback.IsLoopback() || gossipLoopback.Zone() != "" ||
		!transportLoopback.IsValid() || !transportLoopback.IsLoopback() || transportLoopback.Zone() != "" {
		return Descriptor{}, ErrDescriptor
	}
	gossip, err := netip.ParseAddrPort(node.Addr)
	if err != nil || gossip.Port() == 0 {
		return Descriptor{}, ErrDescriptor
	}
	port, err := strconv.ParseUint(node.Meta[internode.MetadataPort], 10, 16)
	if err != nil || port == 0 {
		return Descriptor{}, ErrDescriptor
	}
	descriptor := Descriptor{
		Version:   1,
		Execution: execution,
		Node:      node.ID,
		Gossip:    netip.AddrPortFrom(gossipLoopback, gossip.Port()).String(),
		Transport: netip.AddrPortFrom(transportLoopback, uint16(port)).String(),
		PublicKey: node.Meta[internode.MetadataPublicKey],
	}
	if err := descriptor.validate(); err != nil {
		return Descriptor{}, err
	}
	return descriptor, nil
}

// MatchesNode authenticates a local alias against the live membership record.
// Execution remains fenced by re-reading the exact protected descriptor and
// enrollment after connection; membership itself does not carry that value.
func (d Descriptor) MatchesNode(node cluster.NodeInfo) bool {
	if d.validate() != nil || node.ID != d.Node || node.Meta[internode.MetadataPublicKey] != d.PublicKey {
		return false
	}
	gossip, err := netip.ParseAddrPort(node.Addr)
	if err != nil {
		return false
	}
	localGossip, err := netip.ParseAddrPort(d.Gossip)
	if err != nil || gossip.Port() != localGossip.Port() {
		return false
	}
	port, err := strconv.ParseUint(node.Meta[internode.MetadataPort], 10, 16)
	if err != nil {
		return false
	}
	localTransport, err := netip.ParseAddrPort(d.Transport)
	return err == nil && uint64(localTransport.Port()) == port
}

// Decode rejects unknown, duplicate, case-aliased, missing and null fields.
func Decode(data []byte) (Descriptor, error) {
	if len(data) == 0 || len(data) > MaxBytes || !utf8.Valid(data) {
		return Descriptor{}, ErrDescriptor
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	first, err := dec.Token()
	if err != nil || first != json.Delim('{') {
		return Descriptor{}, ErrDescriptor
	}
	fields := make(map[string]json.RawMessage, 10)
	for dec.More() {
		token, err := dec.Token()
		if err != nil {
			return Descriptor{}, ErrDescriptor
		}
		name, ok := token.(string)
		if !ok || fields[name] != nil {
			return Descriptor{}, ErrDescriptor
		}
		switch name {
		case "version", "execution", "node", "gossip", "transport", "public_key", "client_revision", "supervisor", "join", "launch":
		default:
			return Descriptor{}, ErrDescriptor
		}
		var value json.RawMessage
		if err := dec.Decode(&value); err != nil || bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return Descriptor{}, ErrDescriptor
		}
		fields[name] = value
	}
	last, err := dec.Token()
	// Six fields are required; the owner adds its join listener once it
	// listens and its supervisor address once the supervisor has registered,
	// and names its launch identity when a client started it.
	required := 6
	for _, optional := range []string{"client_revision", "supervisor", "join", "launch"} {
		if fields[optional] != nil {
			required++
		}
	}
	if err != nil || last != json.Delim('}') || len(fields) != required {
		return Descriptor{}, ErrDescriptor
	}
	if _, err := dec.Token(); err != io.EOF {
		return Descriptor{}, ErrDescriptor
	}
	var d Descriptor
	if err := json.Unmarshal(data, &d); err != nil {
		return Descriptor{}, ErrDescriptor
	}
	if err := d.validate(); err != nil {
		return Descriptor{}, err
	}
	return d, nil
}
