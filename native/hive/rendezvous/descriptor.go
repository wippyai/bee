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
	"github.com/wippyai/runtime/cluster/internode"
)

const MaxBytes = 4096

var ErrDescriptor = errors.New("invalid Bee mesh rendezvous descriptor")

// Descriptor contains public discovery data only. Execution identifies one
// owner invocation; reconnect must verify a live owner and request fresh grants.
type Descriptor struct {
	Version   int    `json:"version"`
	Execution string `json:"execution"`
	Node      string `json:"node"`
	Gossip    string `json:"gossip"`
	Transport string `json:"transport"`
	PublicKey string `json:"public_key"`
}

func (d Descriptor) validate() error {
	if d.Version != 1 || len(d.Execution) != 32 || len(d.Node) == 0 || len(d.Node) > 128 {
		return ErrDescriptor
	}
	if _, err := hex.DecodeString(d.Execution); err != nil {
		return ErrDescriptor
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
	return nil
}

// Capture builds a descriptor from the local membership snapshot after native
// cluster startup. Callers must hold the application-state lock and publish only
// their own live node. This function cannot infer socket ownership from values.
// Literal IP endpoints are required; DNS-only advertisements are not supported.
func Capture(node cluster.NodeInfo, execution string) (Descriptor, error) {
	gossip, err := netip.ParseAddrPort(node.Addr)
	if err != nil {
		return Descriptor{}, ErrDescriptor
	}
	port, err := strconv.ParseUint(node.Meta[internode.MetadataPort], 10, 16)
	if err != nil || port == 0 {
		return Descriptor{}, ErrDescriptor
	}
	address := gossip.Addr()
	if advertised := node.Meta[internode.MetadataAdvertiseAddr]; advertised != "" {
		address, err = netip.ParseAddr(advertised)
		if err != nil {
			return Descriptor{}, ErrDescriptor
		}
		port, err = strconv.ParseUint(node.Meta[internode.MetadataAdvertisePort], 10, 16)
		if err != nil || port == 0 {
			return Descriptor{}, ErrDescriptor
		}
	}
	d := Descriptor{Version: 1, Execution: execution, Node: node.ID, Gossip: gossip.String(),
		Transport: netip.AddrPortFrom(address, uint16(port)).String(), PublicKey: node.Meta[internode.MetadataPublicKey]}
	if err := d.validate(); err != nil {
		return Descriptor{}, err
	}
	return d, nil
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
	fields := make(map[string]json.RawMessage, 6)
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
		case "version", "execution", "node", "gossip", "transport", "public_key":
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
	if err != nil || last != json.Delim('}') || len(fields) != 6 {
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
