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
	"sync/atomic"
	"time"

	"go.uber.org/zap"

	"github.com/wippyai/bee/native/hive/invite"
	"github.com/wippyai/bee/native/hive/meshtls"
	"github.com/wippyai/bee/native/hive/rendezvous"
	"github.com/wippyai/runtime/api/boot"
	clusterapi "github.com/wippyai/runtime/api/cluster"
	"github.com/wippyai/runtime/api/event"
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
	// published is the advertise address this boot last told the mesh about.
	// The component republishes it through Membership.UpdateMeta when the
	// host's own pick changes, so peers learn the new internode endpoint
	// without a restart.
	published netip.Addr
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
	// reached is the local address an admitted join connection arrived on.
	// The listener records it so this node advertises a path the peer proved
	// it can reach.
	reached atomic.Pointer[netip.Addr]
}

// reachedAddress returns the address the last admitted join arrived on.
func (a *admitter) reachedAddress() (netip.Addr, bool) {
	if value := a.reached.Load(); value != nil {
		return *value, true
	}
	return netip.Addr{}, false
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
	// The listener owns the accepted socket, so it can report the local
	// address each admitted join arrived on before the handshake is answered.
	servedListener := &reachedListener{Listener: listener, admitter: a}
	// The node states whether it expects to be dialed, through the membership
	// metadata the runtime re-broadcasts. Its internode endpoint needs no
	// metadata: the runtime dials a member at its membership address, which the
	// owner selected from hive/advertise at boot.
	publishMeshMeta(membership, meshDialHint(l.state))
	l.published = l.address
	served, recorded := make(chan struct{}), make(chan struct{})
	updates := subscribeNodeUpdates(lifetime, ctx)
	go func() {
		defer close(served)
		defer redeem.Close()
		if err := invite.Serve(lifetime, servedListener, identity, a.admit); err != nil {
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
			if err := l.adoptReachedAddress(a); err != nil {
				log.Warn("hive reached address record failed", zap.Error(err))
			}
			if err := l.republishAddress(membership); err != nil {
				log.Warn("hive address republish failed", zap.Error(err))
			}
			select {
			case <-lifetime.Done():
				return
			case <-updates:
				if err := recordAddresses(l.state, membership); err != nil {
					log.Warn("hive address record failed", zap.Error(err))
				}
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

// reachedListener reports the local address of each accepted join connection
// to the admitter before the handshake reads it.
type reachedListener struct {
	net.Listener
	admitter *admitter
}

func (l *reachedListener) Accept() (net.Conn, error) {
	connection, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	l.admitter.observeReached(connection.RemoteAddr(), connection.LocalAddr())
	return connection, nil
}

// adoptReachedAddress persists the address the last admitted join arrived on,
// so this node advertises a path a peer proved it can reach. A node whose
// automatic pick is not routable from one peer therefore stays reachable
// without any operator configuration.
func (l *joinListenerComponent) adoptReachedAddress(a *admitter) error {
	reached, ok := a.reachedAddress()
	if !ok {
		return nil
	}
	assigned, err := assignedInterfaceAddresses()
	if err != nil {
		return err
	}
	tailnet, _ := tailscaleIdentity()
	_, _, err = applyReachedAddress(ownerDirectory(l.state), reached.String(), assigned, tailnet)
	return err
}

// republishAddress tells the mesh about this node's dial state when the
// address it advertises to the mesh changed since the last publication. The
// internode endpoint follows the membership address the runtime already knows,
// so only the additive dial direction is republished: a runtime without the
// internode dial-direction hook ignores the unknown key.
func (l *joinListenerComponent) republishAddress(membership clusterapi.Membership) error {
	address, err := resolveAdvertiseAddress(l.state)
	if err != nil {
		return err
	}
	if address == l.published {
		return nil
	}
	publishMeshMeta(membership, meshDialHint(l.state))
	l.published = address
	return nil
}

// publishMeshMeta advertises this node's dial direction through the membership
// metadata the runtime re-broadcasts. The internode endpoint is not published:
// the runtime dials a member at its membership address.
func publishMeshMeta(membership clusterapi.Membership, hint string) {
	if hint == "" {
		return
	}
	membership.UpdateMeta(map[string]string{dialMetadataKey: hint})
}

// subscribeNodeUpdates reports peer join, leave and metadata changes from the
// event bus. The peer address files are rewritten on every report, so a peer
// that restarts with a new address is seeded at its new address on the next
// boot. A bus is optional: without one the periodic record still runs.
func subscribeNodeUpdates(lifetime context.Context, ctx context.Context) <-chan struct{} {
	updates := make(chan struct{}, 1)
	bus := event.GetBus(ctx)
	if bus == nil {
		return updates
	}
	events := make(chan event.Event, 16)
	subscriber, err := bus.Subscribe(lifetime, clusterapi.System, events)
	if err != nil {
		return updates
	}
	go func() {
		defer bus.Unsubscribe(context.WithoutCancel(lifetime), subscriber)
		for {
			select {
			case <-lifetime.Done():
				return
			case message := <-events:
				switch message.Kind {
				case clusterapi.NodeJoined, clusterapi.NodeLeft, clusterapi.NodeUpdated:
				default:
					continue
				}
				select {
				case updates <- struct{}{}:
				default:
				}
			}
		}
	}()
	return updates
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

// observeReached records the local address one accepted join connection
// arrived on. It is the address this node must advertise to be reachable from
// that peer, so it outranks the automatic pick while this host owns it.
//
// Only a peer on another machine teaches anything. A node on this host is
// already reachable through the automatic pick, and the local address of a
// same-host connection may be an address no other machine can route.
func (a *admitter) observeReached(remote, local net.Addr) {
	assigned, err := assignedInterfaceAddresses()
	if err != nil {
		return
	}
	tailnet, _ := tailscaleIdentity()
	if isAssignedLocally(remoteAddress(remote), assigned, tailnet) {
		return
	}
	address, ok := localAddress(local)
	if !ok || !isAssignedLocally(address, assigned, tailnet) {
		return
	}
	value := address
	a.reached.Store(&value)
}

// remoteAddress reads the peer IP of an accepted TCP connection.
func remoteAddress(connection net.Addr) netip.Addr {
	tcp, ok := connection.(*net.TCPAddr)
	if !ok {
		return netip.Addr{}
	}
	address, ok := netip.AddrFromSlice(tcp.IP)
	if !ok {
		return netip.Addr{}
	}
	return address.Unmap()
}

// localAddress reads the local IP of an accepted TCP connection.
func localAddress(connection net.Addr) (netip.Addr, bool) {
	tcp, ok := connection.(*net.TCPAddr)
	if !ok {
		return netip.Addr{}, false
	}
	address, ok := netip.AddrFromSlice(tcp.IP)
	if !ok {
		return netip.Addr{}, false
	}
	address = address.Unmap()
	if address.IsLoopback() || address.IsUnspecified() {
		return netip.Addr{}, false
	}
	return address, true
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
	return invite.Admission{Node: a.node, Gossip: a.gossipSeed(), Secret: strings.TrimSpace(string(secret)),
		Certificate: string(leaf), Authorities: string(pool)}, nil
}

// gossipSeed is the address the joiner seeds this node at. A remote joiner
// proved it can reach the local address its join connection arrived on, so
// that address with the live gossip port is a seed it can actually use. When
// the join came from this host, or no path was observed, the node's own
// gossip address stands.
func (a *admitter) gossipSeed() string {
	local := a.membership.LocalNode()
	reached, ok := a.reachedAddress()
	if !ok {
		return local.Addr
	}
	address, err := netip.ParseAddrPort(local.Addr)
	if err != nil || address.Port() == 0 {
		return local.Addr
	}
	return netip.AddrPortFrom(reached, address.Port()).String()
}
