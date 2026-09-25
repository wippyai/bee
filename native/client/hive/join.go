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
)

// The invite operations of the owner supervisor (src/hive_host/supervisor/invites.lua).
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

// InviteRecord is one invite the supervisor recorded.
type InviteRecord struct {
	ID        string `json:"invite_id"`
	Status    string `json:"status"`
	ExpiresAt string `json:"expires_at"`
	Node      string `json:"node_id,omitempty"`
}

// Peer is one Hive peer and the state of its supervisor session.
type Peer struct {
	Node    string `json:"node_id"`
	Session string `json:"session"`
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

func (j *Join) call(ctx context.Context, operation string, input any, into any) error {
	return callService(ctx, j.client, Owner{Node: j.owner, Service: JoinService}, operation, input, into)
}

// callService makes one call of an owner service under a fresh idempotency
// key and decodes its value strictly into into. A refusal is a *Rejected.
func callService(ctx context.Context, client *Client, owner Owner, operation string, input any, into any) error {
	raw, err := json.Marshal(input)
	if err != nil {
		return err
	}
	var key [16]byte
	if _, err := rand.Read(key[:]); err != nil {
		return err
	}
	reply, err := client.Call(ctx, Operation{Owner: owner, Ref: operation, Key: hex.EncodeToString(key[:]), Input: raw})
	if err != nil {
		return err
	}
	if !reply.OK {
		if reply.Fault == nil {
			return ErrProtocol
		}
		return &Rejected{Fault: *reply.Fault}
	}
	if err := strict(reply.Value, into); err != nil {
		return ErrProtocol
	}
	return nil
}

// list decodes a Lua list, which the native exporter spells {} when empty.
func list[T any](raw json.RawMessage) ([]T, error) {
	if bytes.Equal(bytes.TrimSpace(raw), []byte("{}")) {
		return nil, nil
	}
	var result []T
	if err := strict(raw, &result); err != nil {
		return nil, ErrProtocol
	}
	return result, nil
}

func (j *Join) Invite(ctx context.Context) (Invitation, error) {
	var result Invitation
	if err := j.call(ctx, JoinInvite, struct{}{}, &result); err != nil {
		return Invitation{}, err
	}
	if len(result.ID) != 32 || len(result.Secret) != 64 || !canonicalTime(result.ExpiresAt) {
		return Invitation{}, ErrProtocol
	}
	return result, nil
}

func (j *Join) Invites(ctx context.Context) ([]InviteRecord, error) {
	var value struct {
		Invites json.RawMessage `json:"invites"`
	}
	if err := j.call(ctx, JoinInvites, struct{}{}, &value); err != nil {
		return nil, err
	}
	return list[InviteRecord](value.Invites)
}

func (j *Join) Revoke(ctx context.Context, id string) (InviteRecord, error) {
	var result InviteRecord
	err := j.call(ctx, JoinRevoke, struct {
		ID string `json:"invite_id"`
	}{id}, &result)
	return result, err
}

func (j *Join) Peers(ctx context.Context) (PeerView, error) {
	var value struct {
		Node  string          `json:"node_id"`
		Peers json.RawMessage `json:"peers"`
	}
	if err := j.call(ctx, JoinPeers, struct{}{}, &value); err != nil {
		return PeerView{}, err
	}
	peers, err := list[Peer](value.Peers)
	if err != nil || !identifier(value.Node) {
		return PeerView{}, ErrProtocol
	}
	return PeerView{Node: value.Node, Peers: peers}, nil
}

// Redeem consumes invite id for node when secret matches. Only the owner's
// join listener endpoint is admitted to call it.
func (j *Join) Redeem(ctx context.Context, id, secret, node string) error {
	var result struct {
		ID   string `json:"invite_id"`
		Node string `json:"node_id"`
	}
	if err := j.call(ctx, JoinRedeem, struct {
		ID     string `json:"invite_id"`
		Secret string `json:"secret"`
		Node   string `json:"node_id"`
	}{id, secret, node}, &result); err != nil {
		return err
	}
	if result.ID != id || result.Node != node {
		return errors.New("supervisor redeemed another invite")
	}
	return nil
}
