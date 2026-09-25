// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"go.uber.org/zap"

	"github.com/wippyai/bee/native/hive/invite"
	"github.com/wippyai/bee/native/hive/meshtls"
	"github.com/wippyai/bee/native/hive/rendezvous"
	"github.com/wippyai/runtime/api/boot"
	clusterapi "github.com/wippyai/runtime/api/cluster"
	"github.com/wippyai/runtime/api/logs"
)

// joinHost is the native host of the owner's join listener. The supervisor
// admits invite redemption only from this host on its own node.
const joinHost = "bee.hive:join_host"

// maxJoinAddresses bounds the addresses a joiner asks its leaf to carry.
const maxJoinAddresses = 8

// redeemer consumes an invite through the owner's supervisor. A definite
// supervisor refusal is returned as *invite.Refused.
type redeemer interface {
	Redeem(ctx context.Context, id, secret, node string) error
	Close()
}

type joinListenerComponent struct {
	state   string
	node    string
	address netip.Addr
	cancel  context.CancelFunc
	done    chan struct{}
}

// joinListener serves invite redemption for the owner of state and records the
// hive's addresses the next boot binds and seeds. It depends on the cluster so
// its admission can name the live gossip address.
func joinListener(state string, address netip.Addr) (boot.Component, error) {
	if !filepath.IsAbs(state) {
		return nil, errors.New("join listener requires an absolute state directory")
	}
	l := &joinListenerComponent{state: state, node: ownerNodeName(state), address: address}
	return boot.New(boot.P{Name: "bee.launch.join", DependsOn: []string{"cluster"}, Start: l.Start, Stop: l.Stop}), nil
}

// admitter answers one joiner for the running owner.
type admitter struct {
	state      string
	node       string
	authority  meshtls.Authority
	membership clusterapi.Membership
	redeem     redeemer
	// serial keeps one redemption in flight: all share the listener's one
	// supervisor endpoint.
	serial sync.Mutex
}

func (l *joinListenerComponent) Start(ctx context.Context) error {
	directory := ownerDirectory(l.state)
	data, err := os.ReadFile(filepath.Join(directory, internodeKeyName))
	if err != nil {
		return err
	}
	identity, err := decodeIdentity(strings.TrimSpace(string(data)))
	if err != nil {
		return err
	}
	authority, err := ensureAuthority(directory, time.Now())
	if err != nil {
		return err
	}
	membership := clusterapi.GetMembership(ctx)
	if membership == nil {
		return errors.New("join listener requires the running mesh")
	}
	store, err := rendezvous.New(filepath.Join(l.state, rendezvous.DirectoryName))
	if err != nil {
		return err
	}
	redeem, err := openRedeemer(ctx, l.node)
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp", netip.AddrPortFrom(meshBindAddress(l.address), 0).String())
	if err != nil {
		redeem.Close()
		return err
	}
	descriptor, err := store.Read(ctx)
	if err == nil {
		descriptor.Join = netip.AddrPortFrom(l.address, uint16(listener.Addr().(*net.TCPAddr).Port)).String()
		err = store.Publish(ctx, descriptor)
	}
	if err != nil {
		redeem.Close()
		return errors.Join(err, listener.Close())
	}
	log := logs.GetLogger(ctx).Named("bee.launch.join")
	lifetime, cancel := context.WithCancel(context.WithoutCancel(ctx))
	l.cancel, l.done = cancel, make(chan struct{})
	a := &admitter{state: l.state, node: l.node, authority: authority, membership: membership, redeem: redeem}
	served, recorded := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(served)
		defer redeem.Close()
		if err := invite.Serve(lifetime, listener, identity, a.admit); err != nil {
			log.Warn("join listener stopped", zap.Error(err))
		}
	}()
	go func() {
		defer close(recorded)
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			if err := recordAddresses(l.state, membership); err != nil {
				log.Warn("hive address record failed", zap.Error(err))
			}
			select {
			case <-lifetime.Done():
				return
			case <-ticker.C:
			}
		}
	}()
	go func() {
		<-served
		<-recorded
		close(l.done)
	}()
	return nil
}

func (l *joinListenerComponent) Stop(context.Context) error {
	if l.cancel != nil {
		l.cancel()
		<-l.done
		l.cancel = nil
	}
	return nil
}

func refuse(code, message string) *invite.Refused {
	return &invite.Refused{Code: code, Message: message}
}

// admit redeems the joiner's invite through the supervisor, pins the joiner's
// identity key as a Hive peer and certifies its mesh leaf.
func (a *admitter) admit(ctx context.Context, peer ed25519.PublicKey, request invite.Request) (invite.Admission, *invite.Refused) {
	if !invite.ValidNode(request.Node) || request.Node == a.node || !validTrustedName(request.Node) {
		return invite.Admission{}, refuse("INVALID_ARGUMENT", "the joining node identity is invalid")
	}
	key, err := base64.RawStdEncoding.DecodeString(request.Key)
	if err != nil || len(key) != ed25519.PublicKeySize {
		return invite.Admission{}, refuse("INVALID_ARGUMENT", "the joining node's mesh key is invalid")
	}
	if len(request.Addresses) > maxJoinAddresses {
		return invite.Admission{}, refuse("INVALID_ARGUMENT", "too many joining node addresses")
	}
	addresses := make([]netip.Addr, 0, len(request.Addresses))
	for _, value := range request.Addresses {
		address, err := netip.ParseAddr(value)
		if err != nil || address.Zone() != "" || address.IsUnspecified() {
			return invite.Admission{}, refuse("INVALID_ARGUMENT", "a joining node address is invalid")
		}
		addresses = append(addresses, address)
	}
	a.serial.Lock()
	defer a.serial.Unlock()
	if err := a.redeem.Redeem(ctx, request.Invite, request.Secret, request.Node); err != nil {
		var refused *invite.Refused
		if errors.As(err, &refused) {
			return invite.Admission{}, refused
		}
		return invite.Admission{}, refuse("UNAVAILABLE", "the hive node could not redeem the invite")
	}
	now := time.Now()
	leaf, err := a.authority.Issue(ed25519.PublicKey(key), addresses, now)
	if err != nil {
		return invite.Admission{}, refuse("INTERNAL", "the hive node could not certify the joining node")
	}
	secretPath, err := membershipSecretPath(a.state)
	if err != nil {
		return invite.Admission{}, refuse("INTERNAL", "the hive mesh secret is unavailable")
	}
	secret, err := os.ReadFile(secretPath)
	if err != nil {
		return invite.Admission{}, refuse("INTERNAL", "the hive mesh secret is unavailable")
	}
	pool, err := os.ReadFile(filepath.Join(ownerDirectory(a.state), meshtls.AuthoritiesFile))
	if err != nil {
		return invite.Admission{}, refuse("INTERNAL", "the hive authorities are unavailable")
	}
	pin := filepath.Join(ownerPeersDirectory(a.state), request.Node+".pub")
	if err := writeOwnerFile(pin, []byte(base64.RawStdEncoding.EncodeToString(peer)+"\n")); err != nil {
		return invite.Admission{}, refuse("INTERNAL", "the hive node could not pin the joining node")
	}
	return invite.Admission{Node: a.node, Gossip: a.membership.LocalNode().Addr, Secret: strings.TrimSpace(string(secret)),
		Certificate: string(leaf), Authorities: string(pool)}, nil
}
