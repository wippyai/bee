// SPDX-License-Identifier: MIT

package hive

import (
	"crypto/ed25519"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"sync"
	"sync/atomic"

	clusterapi "github.com/wippyai/runtime/api/cluster"
	"github.com/wippyai/runtime/cluster/internode"
)

// nodeName matches the node ids Bee issues: a folder's `bee-<hex>`, an
// in-memory client's `bee-client-<hex>`, and the runtime's host-and-folder
// UUIDv5 a folder with earlier state adopted as its stored identity.
var nodeName = regexp.MustCompile(`^(bee-(client-)?[0-9a-f]{32}|[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})$`)

// isNodeName reports whether name is a node id Bee issues.
func isNodeName(name string) bool { return nodeName.MatchString(name) }

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
	if bound == nil || !isNodeName(node) {
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

var (
	heldMu sync.Mutex
	// held keeps the port locks open for the life of the process.
	held []*os.File
)

// portLock is the file whose lock claims the machine's gossip port.
const portLock = "port.lock"

// claimGossipPort returns port when this process is the first on the machine to
// claim it and both gossip protocols can bind it, else 0 so the runtime picks
// one. The claim is a file lock held until the process ends, so bees starting
// together never contend for the port; the first holds the port other machines
// dial.
func claimGossipPort(dir string, port int) int {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return 0
	}
	file, err := os.OpenFile(filepath.Join(dir, portLock), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return 0
	}
	if !tryLock(file) {
		_ = file.Close()
		return 0
	}
	heldMu.Lock()
	held = append(held, file)
	heldMu.Unlock()
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
