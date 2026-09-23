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
	"net/netip"
	"net/url"
	"strings"
)

// Scheme prefixes every invite line.
const Scheme = "bee-hive"

// ErrInvite refuses a malformed invite line.
var ErrInvite = errors.New("invalid Bee Hive invite")

// Invite is one decoded invite line.
type Invite struct {
	ID          string
	Secret      string
	Address     netip.AddrPort
	Node        string
	Fingerprint string
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
	return lowerHex(i.ID, 32) && lowerHex(i.Secret, 64) && i.Address.IsValid() && i.Address.Port() != 0 &&
		i.Address.Addr().Zone() == "" && !i.Address.Addr().IsUnspecified() && ValidNode(i.Node) && lowerHex(i.Fingerprint, 64)
}

// String renders the one-line invite:
//
//	bee-hive://ID:SECRET@HOST:PORT/NODE?key=FINGERPRINT
func (i Invite) String() string {
	return Scheme + "://" + i.ID + ":" + i.Secret + "@" + i.Address.String() + "/" + i.Node + "?key=" + i.Fingerprint
}

// Parse decodes one invite line exactly as String renders it.
func Parse(line string) (Invite, error) {
	line = strings.TrimSpace(line)
	if len(line) > 512 {
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
	if err != nil || len(query) != 1 || len(query["key"]) != 1 {
		return Invite{}, ErrInvite
	}
	result := Invite{ID: parsed.User.Username(), Secret: secret, Address: address,
		Node: strings.TrimPrefix(parsed.Path, "/"), Fingerprint: query["key"][0]}
	if !result.valid() || result.String() != line {
		return Invite{}, ErrInvite
	}
	return result, nil
}
