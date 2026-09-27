//go:build meshclient

// SPDX-License-Identifier: MIT
package hive

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"

	"github.com/wippyai/bee/native/internal/jsonwire"
)

// The invite operations of the owner supervisor (src/hive/supervisor/invites.lua).
const (
	JoinService = "bee.hive.join"
	JoinInvite  = "bee.hive.join:invite"
	JoinInvites = "bee.hive.join:invites"
	JoinRevoke  = "bee.hive.join:revoke"
	JoinPeers   = "bee.hive.join:peers"
	JoinRedeem  = "bee.hive.join:redeem"
)

// Invitation is a freshly minted invite: its identity, its secret, which the
// supervisor keeps only as a digest, and its expiry.
type Invitation struct {
	ID        string `json:"invite_id"`
	Secret    string `json:"secret"`
	ExpiresAt string `json:"expires_at"`
}

// InviteStatus is the supervisor's state for a minted invite.
type InviteStatus string

const (
	InvitePending InviteStatus = "pending"
	InviteUsed    InviteStatus = "used"
	InviteRevoked InviteStatus = "revoked"
	InviteExpired InviteStatus = "expired"
)

// InviteRecord is one invite the supervisor recorded.
type InviteRecord struct {
	ID        string       `json:"invite_id"`
	Status    InviteStatus `json:"status"`
	ExpiresAt string       `json:"expires_at"`
	Node      string       `json:"node_id,omitempty"`
}

// PeerSession is the supervisor session state for one Hive peer.
type PeerSession string

const (
	PeerEstablished PeerSession = "established"
	PeerPending     PeerSession = "pending"
	PeerNone        PeerSession = "none"
)

// Peer is one Hive peer and the state of its supervisor session.
type Peer struct {
	Node    string      `json:"node_id"`
	Session PeerSession `json:"session"`
}

// PeerView is the supervisor's own node and its Hive peers.
type PeerView struct {
	Node  string `json:"node_id"`
	Peers []Peer `json:"peers"`
}

// Join calls the invite operations of one owner supervisor.
type Join struct {
	client *Client
	owner  string
}

func NewJoin(lifetime context.Context, transport Transport, ownerNode string) (*Join, error) {
	client, err := NewClient(lifetime, transport, ownerNode)
	if err != nil {
		return nil, err
	}
	return JoinOver(client), nil
}

// JoinOver calls the invite operations over an existing client of the owner.
func JoinOver(client *Client) *Join {
	return &Join{client: client, owner: client.owner}
}

func (j *Join) call(ctx context.Context, operation string, input any) (json.RawMessage, error) {
	return callService(ctx, j.client, Owner{Node: j.owner, Service: JoinService}, operation, input)
}

// callService makes one call of an owner service under a fresh idempotency
// key and returns its bounded JSON value for the operation decoder. A refusal
// is a *Rejected.
func callService(ctx context.Context, client *Client, owner Owner, operation string, input any) (json.RawMessage, error) {
	raw, err := json.Marshal(input)
	if err != nil {
		return nil, err
	}
	var key [16]byte
	if _, err := rand.Read(key[:]); err != nil {
		return nil, err
	}
	reply, err := client.Call(ctx, Operation{Owner: owner, Ref: operation, Key: hex.EncodeToString(key[:]), Input: raw})
	if err != nil {
		return nil, err
	}
	if !reply.OK {
		if reply.Fault == nil {
			return nil, ErrProtocol
		}
		return nil, &Rejected{Fault: *reply.Fault}
	}
	return bytes.Clone(reply.Value), nil
}

func decodeServiceObject[T any](raw []byte, required ...string) (T, error) {
	value, err := jsonwire.DecodeObject[T](raw, maxBytes, required...)
	if err != nil {
		return value, ErrProtocol
	}
	return value, nil
}

// list decodes a Lua list, which the native exporter spells {} when empty.
func list[T any](raw json.RawMessage, maxItems int, required ...string) ([]T, error) {
	trimmed := bytes.TrimSpace(raw)
	if bytes.Equal(trimmed, []byte("{}")) {
		return nil, nil
	}
	if len(trimmed) == 0 || trimmed[0] != '[' || !uniqueJSON(trimmed) {
		return nil, ErrProtocol
	}
	var items []json.RawMessage
	if json.Unmarshal(trimmed, &items) != nil || len(items) > maxItems {
		return nil, ErrProtocol
	}
	result := make([]T, len(items))
	for index, item := range items {
		value, err := jsonwire.DecodeObject[T](item, maxBytes, required...)
		if err != nil {
			return nil, ErrProtocol
		}
		result[index] = value
	}
	return result, nil
}

func validInviteID(value string) bool { return durableID(value) }

func validInviteStatus(value InviteStatus) bool {
	switch value {
	case InvitePending, InviteUsed, InviteRevoked, InviteExpired:
		return true
	default:
		return false
	}
}

func validInviteRecord(record InviteRecord) bool {
	if !validInviteID(record.ID) || !validInviteStatus(record.Status) || !canonicalTime(record.ExpiresAt) {
		return false
	}
	if record.Node != "" {
		return record.Status == InviteUsed && identifier(record.Node)
	}
	return record.Status != InviteUsed
}

func validPeerSession(value PeerSession) bool {
	switch value {
	case PeerEstablished, PeerPending, PeerNone:
		return true
	default:
		return false
	}
}

func (j *Join) Invite(ctx context.Context) (Invitation, error) {
	raw, err := j.call(ctx, JoinInvite, struct{}{})
	if err != nil {
		return Invitation{}, err
	}
	result, err := decodeServiceObject[Invitation](raw, "invite_id", "secret", "expires_at")
	if err != nil {
		return Invitation{}, err
	}
	if !validInviteID(result.ID) || !secret(result.Secret) || !canonicalTime(result.ExpiresAt) {
		return Invitation{}, ErrProtocol
	}
	return result, nil
}

func (j *Join) Invites(ctx context.Context) ([]InviteRecord, error) {
	value, err := j.call(ctx, JoinInvites, struct{}{})
	if err != nil {
		return nil, err
	}
	var page struct {
		Invites json.RawMessage `json:"invites"`
	}
	page, err = decodeServiceObject[struct {
		Invites json.RawMessage `json:"invites"`
	}](value, "invites")
	if err != nil {
		return nil, err
	}
	records, err := list[InviteRecord](page.Invites, 64, "invite_id", "status", "expires_at")
	if err != nil {
		return nil, err
	}
	for _, record := range records {
		if !validInviteRecord(record) {
			return nil, ErrProtocol
		}
	}
	return records, nil
}

func (j *Join) Revoke(ctx context.Context, id string) (InviteRecord, error) {
	if !validInviteID(id) {
		return InviteRecord{}, ErrProtocol
	}
	raw, err := j.call(ctx, JoinRevoke, struct {
		ID string `json:"invite_id"`
	}{id})
	if err != nil {
		return InviteRecord{}, err
	}
	result, err := decodeServiceObject[InviteRecord](raw, "invite_id", "status", "expires_at")
	if err != nil || result.ID != id || !validInviteRecord(result) {
		return InviteRecord{}, ErrProtocol
	}
	return result, nil
}

func (j *Join) Peers(ctx context.Context) (PeerView, error) {
	raw, err := j.call(ctx, JoinPeers, struct{}{})
	if err != nil {
		return PeerView{}, err
	}
	value, err := decodeServiceObject[struct {
		Node  string          `json:"node_id"`
		Peers json.RawMessage `json:"peers"`
	}](raw, "node_id", "peers")
	if err != nil {
		return PeerView{}, err
	}
	peers, err := list[Peer](value.Peers, 64, "node_id", "session")
	if err != nil || !identifier(value.Node) {
		return PeerView{}, ErrProtocol
	}
	for _, peer := range peers {
		if !identifier(peer.Node) || !validPeerSession(peer.Session) {
			return PeerView{}, ErrProtocol
		}
	}
	return PeerView{Node: value.Node, Peers: peers}, nil
}

func secret(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, character := range value {
		if character < '0' || character > '9' {
			if character < 'a' || character > 'f' {
				return false
			}
		}
	}
	return true
}

// Redeem consumes invite id for node when secret matches. Only the owner's
// join listener endpoint is admitted to call it.
func (j *Join) Redeem(ctx context.Context, id, secret, node string) error {
	raw, err := j.call(ctx, JoinRedeem, struct {
		ID     string `json:"invite_id"`
		Secret string `json:"secret"`
		Node   string `json:"node_id"`
	}{id, secret, node})
	if err != nil {
		return err
	}
	result, err := decodeServiceObject[struct {
		ID   string `json:"invite_id"`
		Node string `json:"node_id"`
	}](raw, "invite_id", "node_id")
	if err != nil {
		return err
	}
	if result.ID != id || result.Node != node {
		return errors.New("supervisor redeemed another invite")
	}
	return nil
}
