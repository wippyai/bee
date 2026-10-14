// SPDX-License-Identifier: MIT

// Package invite carries a Hive invite and the handshake that redeems it. An
// invite names the hive node's join address, its node identity and the
// fingerprint of its internode identity key, plus a single-use secret minted by
// the hive node's supervisor. The handshake runs over TLS 1.3: the joiner pins
// the hive node's identity key by the fingerprint before it discloses the
// secret, and proves its own identity key with its client certificate.
package invite

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
)

// Scheme prefixes every invite line.
const Scheme = "bee-hive"

// MaxCandidates bounds alternate endpoints after the URL's primary address.
const MaxCandidates = 8

// MaxInviteBytes bounds the complete pasteable token.
const MaxInviteBytes = 1536

// Candidate is a transport hint. The identity fingerprint, not this address,
// authenticates the peer. Endpoint is a literal IP or a Tailscale MagicDNS name.
type Candidate struct {
	Kind     string
	Scope    string
	Endpoint string
}

func (c Candidate) valid() bool {
	if c.Kind != "interface" && c.Kind != "tailnet" && c.Kind != "magicdns" && c.Kind != "explicit" {
		return false
	}
	if c.Scope != "lan" && c.Scope != "tailnet" && c.Scope != "external" && c.Scope != "vm" && c.Scope != "host" {
		return false
	}
	host, portText, err := net.SplitHostPort(c.Endpoint)
	if err != nil {
		return false
	}
	port, err := strconv.ParseUint(portText, 10, 16)
	if err != nil || port == 0 || strconv.FormatUint(port, 10) != portText {
		return false
	}
	if c.Kind == "magicdns" {
		if c.Scope != "tailnet" || !strings.HasSuffix(host, ".ts.net") || len(host) > 253 || host != strings.ToLower(host) {
			return false
		}
		for _, label := range strings.Split(host, ".") {
			if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
				return false
			}
			for _, r := range label {
				if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-') {
					return false
				}
			}
		}
		return true
	}
	addr, err := netip.ParseAddr(host)
	return err == nil && addr.Zone() == "" && !addr.IsUnspecified() &&
		(!addr.IsLoopback() && !addr.IsLinkLocalUnicast() || c.Scope == "host") &&
		net.JoinHostPort(addr.String(), portText) == c.Endpoint
}

// Valid reports whether the candidate has a bounded, canonical endpoint.
func (c Candidate) Valid() bool { return c.valid() }

// ErrInvite refuses a malformed invite line.
var ErrInvite = errors.New("invalid Bee Hive invite")

// Invite is one decoded invite line.
type Invite struct {
	ID          string
	Secret      string
	Address     netip.AddrPort
	Node        string
	Fingerprint string
	Candidates  []Candidate
}

// Fingerprint is the sha256 of an internode identity public key, in lowercase hex.
func Fingerprint(public ed25519.PublicKey) string {
	sum := sha256.Sum256(public)
	return hex.EncodeToString(sum[:])
}

func lowerHex(value string, size int) bool {
	if len(value) != size {
		return false
	}
	for _, r := range value {
		if !(r >= '0' && r <= '9' || r >= 'a' && r <= 'f') {
			return false
		}
	}
	return true
}

// ValidNode accepts the node identities an invite can carry: 1 to 128 bytes
// of letters, digits, dot, underscore and hyphen.
func ValidNode(node string) bool {
	if node == "" || len(node) > 128 {
		return false
	}
	for _, r := range node {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '.' || r == '_' || r == '-') {
			return false
		}
	}
	return true
}

func (i Invite) valid() bool {
	if len(i.Candidates) > MaxCandidates {
		return false
	}
	seen := map[string]bool{i.Address.String(): true}
	for _, c := range i.Candidates {
		if !c.valid() || seen[c.Endpoint] {
			return false
		}
		seen[c.Endpoint] = true
	}
	return lowerHex(i.ID, 32) && lowerHex(i.Secret, 64) && i.Address.IsValid() && i.Address.Port() != 0 &&
		i.Address.Addr().Zone() == "" && !i.Address.Addr().IsUnspecified() && ValidNode(i.Node) && lowerHex(i.Fingerprint, 64)
}

// String renders the one-line invite, followed by optional URL-escaped
// candidate hints:
//
//	bee-hive://ID:SECRET@HOST:PORT/NODE?key=FINGERPRINT
func (i Invite) String() string {
	line := Scheme + "://" + i.ID + ":" + i.Secret + "@" + i.Address.String() + "/" + i.Node + "?key=" + i.Fingerprint
	for _, c := range i.Candidates {
		line += "&c=" + url.QueryEscape(c.Kind+","+c.Scope+","+c.Endpoint)
	}
	return line
}

// Parse decodes one invite line exactly as String renders it.
func Parse(line string) (Invite, error) {
	line = strings.TrimSpace(line)
	if len(line) > MaxInviteBytes {
		return Invite{}, ErrInvite
	}
	parsed, err := url.Parse(line)
	if err != nil || parsed.Scheme != Scheme || parsed.User == nil || parsed.Fragment != "" || parsed.Opaque != "" {
		return Invite{}, ErrInvite
	}
	secret, present := parsed.User.Password()
	address, err := netip.ParseAddrPort(parsed.Host)
	if !present || err != nil {
		return Invite{}, ErrInvite
	}
	query, err := url.ParseQuery(parsed.RawQuery)
	if err != nil || len(query["key"]) != 1 || len(query) > 2 || len(query["c"]) > MaxCandidates {
		return Invite{}, ErrInvite
	}
	result := Invite{ID: parsed.User.Username(), Secret: secret, Address: address,
		Node: strings.TrimPrefix(parsed.Path, "/"), Fingerprint: query["key"][0]}
	for _, value := range query["c"] {
		fields := strings.Split(value, ",")
		if len(fields) != 3 {
			return Invite{}, ErrInvite
		}
		result.Candidates = append(result.Candidates, Candidate{Kind: fields[0], Scope: fields[1], Endpoint: fields[2]})
	}
	if !result.valid() || result.String() != line {
		return Invite{}, ErrInvite
	}
	return result, nil
}
