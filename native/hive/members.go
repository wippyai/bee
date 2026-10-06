// SPDX-License-Identifier: MIT

package hive

import (
	"crypto/ed25519"
	"net"
	"strconv"
	"strings"
	"sync/atomic"

	clusterapi "github.com/wippyai/runtime/api/cluster"
	"github.com/wippyai/runtime/cluster/internode"
)

// nodePrefix starts the name of every hive node.
const nodePrefix = "bee-"

// Members resolves the identity keys of nodes on other machines from the
// membership the hive's gossip carries. The hive secret is the trust root
// across machines: a node of another machine is trusted under the key it
// advertises, while a node whose key this machine published locally is only
// trusted under that key.
type Members struct {
	membership atomic.Pointer[clusterapi.Membership]
}

func (m *Members) bind(membership clusterapi.Membership) { m.membership.Store(&membership) }

// advertisedKey returns the identity key node advertises in gossip.
func (m *Members) advertisedKey(node string) (ed25519.PublicKey, bool) {
	bound := m.membership.Load()
	if bound == nil || !strings.HasPrefix(node, nodePrefix) {
		return nil, false
	}
	for _, member := range (*bound).Nodes() {
		if string(member.ID) != node {
			continue
		}
		key, err := internode.ParseIdentityPublicKey(member.Meta[internode.MetadataPublicKey])
		if err != nil {
			return nil, false
		}
		return key, true
	}
	return nil, false
}

// freeGossipPort returns port when both gossip protocols can bind it, else 0
// so the runtime picks one. The first node of a machine thus holds the port the
// machine's other hives dial.
func freeGossipPort(port int) int {
	address := net.JoinHostPort("0.0.0.0", strconv.Itoa(port))
	stream, err := net.Listen("tcp", address)
	if err != nil {
		return 0
	}
	defer stream.Close()
	datagram, err := net.ListenPacket("udp", address)
	if err != nil {
		return 0
	}
	_ = datagram.Close()
	return port
}
