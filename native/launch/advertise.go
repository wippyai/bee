// SPDX-License-Identifier: MIT

package launch

import (
	"errors"
	"net/netip"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

const (
	// advertiseFileName persists the address this node advertises to the
	// runtime mesh. The owner picks it automatically (Tailscale, then the
	// first non-virtual LAN address, then loopback when alone) and the next
	// boot reads it back, so no environment variable selects it.
	advertiseFileName = "advertise"
	// natFileName marks a node whose observed join-path IP is not assigned
	// locally: the node stays reachable over the paths its invite carried
	// while the runtime cannot dial it directly.
	natFileName = "nat"
	// reachedFileName records the address a peer actually reached this node
	// on. The listener learns it from the local address of an admitted join
	// connection, so a node whose automatic pick (for example a Tailscale
	// address) is not routable from a particular peer still advertises an
	// address that peer proved it can reach.
	reachedFileName = "reached"
	// dialMetadataKey is the internode metadata key a NATed node publishes so
	// the peer on the other side keeps the connection open instead of dialing
	// an address it cannot reach. The pinned runtime ignores unknown metadata
	// keys; the internode dial-direction hook (Bee runtime hooks H1) consumes
	// it once that hook is present.
	dialMetadataKey = "internode_dial"
	// dialOut tells the peer this node dials out and never expects an inbound
	// dial.
	dialOut = "out"
)

// pickAdvertiseAddress selects the mesh advertise address: a Tailscale
// address first, then the first non-virtual LAN address, then loopback when
// the node is alone.
func pickAdvertiseAddress(assigned []interfaceAddress, tailnet []netip.Addr) netip.Addr {
	for _, address := range tailnet {
		if address.IsValid() && address.Zone() == "" && !address.IsUnspecified() && !address.IsLoopback() {
			return address.Unmap()
		}
	}
	for _, item := range assigned {
		if slices.ContainsFunc(tailnet, func(candidate netip.Addr) bool { return candidate.Unmap() == item.address }) {
			continue
		}
		if virtualInterface(item.name) {
			continue
		}
		if item.address.IsValid() && !item.address.IsLoopback() {
			return item.address
		}
	}
	return netip.MustParseAddr("127.0.0.1")
}

// isAssignedLocally reports whether address is assigned to this host, either
// on an interface, as a Tailscale identity, or as loopback.
func isAssignedLocally(address netip.Addr, assigned []interfaceAddress, tailnet []netip.Addr) bool {
	address = address.Unmap()
	if !address.IsValid() {
		return false
	}
	if address.IsLoopback() {
		return true
	}
	for _, item := range assigned {
		if item.address == address {
			return true
		}
	}
	return slices.ContainsFunc(tailnet, func(candidate netip.Addr) bool { return candidate.Unmap() == address })
}

// readAdvertise returns the persisted advertise address, if one is stored.
func readAdvertise(directory string) (netip.Addr, bool, error) {
	address, err := readAddressFile(filepath.Join(directory, advertiseFileName))
	if errors.Is(err, errNoAddressFile) {
		return netip.Addr{}, false, nil
	}
	return address, err == nil, err
}

// readReached returns the address a peer proved it could reach this node on,
// if one is recorded.
func readReached(directory string) (netip.Addr, bool, error) {
	address, err := readAddressFile(filepath.Join(directory, reachedFileName))
	if errors.Is(err, errNoAddressFile) {
		return netip.Addr{}, false, nil
	}
	return address, err == nil, err
}

// readNAT returns the join-path IP a node observed for itself when that IP is
// not assigned locally, marking the node as NATed.
func readNAT(directory string) (netip.Addr, bool, error) {
	address, err := readAddressFile(filepath.Join(directory, natFileName))
	if errors.Is(err, errNoAddressFile) {
		return netip.Addr{}, false, nil
	}
	return address, err == nil, err
}

var errNoAddressFile = errors.New("no recorded address")

func readAddressFile(path string) (netip.Addr, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return netip.Addr{}, errNoAddressFile
	}
	if err != nil {
		return netip.Addr{}, err
	}
	address, err := netip.ParseAddr(strings.TrimSpace(string(data)))
	if err != nil || address.Zone() != "" || address.IsUnspecified() || !address.IsValid() {
		return netip.Addr{}, errors.New("recorded mesh address is invalid")
	}
	return address.Unmap(), nil
}

// ensureAdvertiseAddress returns the advertise address of this boot: the
// persisted pick while this host still owns it and the live preference order
// does not outrank it, otherwise a fresh Tailscale, LAN or loopback pick that
// is persisted for the next boot. A restart after a DHCP lease change, or a
// Tailscale interface appearing or leaving, therefore never advertises an
// address this host does not own, and always prefers Tailscale when it exists.
func ensureAdvertiseAddress(directory string, assigned []interfaceAddress, tailnet []netip.Addr) (netip.Addr, error) {
	picked := pickAdvertiseAddress(assigned, tailnet)
	persisted, ok, err := readAdvertise(directory)
	if err != nil {
		return netip.Addr{}, err
	}
	if ok && isAssignedLocally(persisted, assigned, tailnet) && keepPersisted(persisted, picked, tailnet) {
		return persisted, nil
	}
	if err := writeChanged(filepath.Join(directory, advertiseFileName), picked.String()); err != nil {
		return netip.Addr{}, err
	}
	return picked, nil
}

// keepPersisted reports whether the stored address still wins over the live
// pick. A Tailscale address outranks any other stored address, so a tailnet
// that comes up between boots is adopted and one that goes away is dropped.
func keepPersisted(persisted, picked netip.Addr, tailnet []netip.Addr) bool {
	inTailnet := func(address netip.Addr) bool {
		return slices.ContainsFunc(tailnet, func(candidate netip.Addr) bool { return candidate.Unmap() == address.Unmap() })
	}
	if inTailnet(persisted) {
		return true
	}
	return !inTailnet(picked)
}

// resolveAdvertiseAddress returns the address this node advertises: the
// address a peer proved it could reach when this host still owns it, otherwise
// the automatic pick.
func resolveAdvertiseAddress(state string) (netip.Addr, error) {
	assigned, err := assignedInterfaceAddresses()
	if err != nil {
		return netip.Addr{}, err
	}
	tailnet, _ := tailscaleIdentity()
	return effectiveAdvertiseAddress(ownerDirectory(state), assigned, tailnet)
}

// effectiveAdvertiseAddress prefers an address a peer reached this node on
// over the automatic pick. A proven path is the only statement about
// reachability this node has, so it wins while it is still assigned locally.
// hive/advertise keeps the automatic pick and hive/reached the proven path, so
// each is replaced independently.
func effectiveAdvertiseAddress(directory string, assigned []interfaceAddress, tailnet []netip.Addr) (netip.Addr, error) {
	picked, err := ensureAdvertiseAddress(directory, assigned, tailnet)
	if err != nil {
		return netip.Addr{}, err
	}
	reached, ok, err := readReached(directory)
	if err != nil || !ok {
		return picked, err
	}
	if reached.IsLoopback() || !isAssignedLocally(reached, assigned, tailnet) {
		return picked, nil
	}
	return reached, nil
}

// applyReachedAddress records the address a peer reached this node on, when
// this host owns it. The listener calls it for every admitted join, so the
// node advertises a path a peer proved works instead of an address that peer
// cannot route. A reached address that is no longer assigned is dropped.
func applyReachedAddress(directory, reached string, assigned []interfaceAddress, tailnet []netip.Addr) (netip.Addr, bool, error) {
	reached = strings.TrimSpace(reached)
	if reached == "" {
		return netip.Addr{}, false, nil
	}
	address, err := netip.ParseAddr(reached)
	if err != nil || !address.IsValid() || address.IsUnspecified() || address.Zone() != "" {
		return netip.Addr{}, false, errors.New("the join connection reported an invalid local address")
	}
	address = address.Unmap()
	if address.IsLoopback() || !isAssignedLocally(address, assigned, tailnet) {
		return netip.Addr{}, false, nil
	}
	if err := writeChanged(filepath.Join(directory, reachedFileName), address.String()); err != nil {
		return netip.Addr{}, false, err
	}
	return address, true, nil
}

// applyObservedAddress replaces the persisted advertise address with the IP
// the inviter observed on the authenticated join TCP when that IP is assigned
// locally. Otherwise the node keeps its pick and records itself as NATed.
func applyObservedAddress(directory, observed string, assigned []interfaceAddress, tailnet []netip.Addr) (netip.Addr, bool, error) {
	observed = strings.TrimSpace(observed)
	if observed == "" {
		// An older hive node does not report the observed path; the pick stands.
		current, err := ensureAdvertiseAddress(directory, assigned, tailnet)
		return current, false, err
	}
	address, err := netip.ParseAddr(observed)
	if err != nil {
		if parsed, portErr := netip.ParseAddrPort(observed); portErr == nil {
			address, err = parsed.Addr(), nil
		}
	}
	if err != nil || !address.IsValid() || address.IsUnspecified() || address.Zone() != "" {
		return netip.Addr{}, false, errors.New("the hive node sent an invalid observed address")
	}
	address = address.Unmap()
	if !address.IsLoopback() && isAssignedLocally(address, assigned, tailnet) {
		if err := writeChanged(filepath.Join(directory, advertiseFileName), address.String()); err != nil {
			return netip.Addr{}, false, err
		}
		if err := os.Remove(filepath.Join(directory, natFileName)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return netip.Addr{}, false, err
		}
		return address, false, nil
	}
	current, err := ensureAdvertiseAddress(directory, assigned, tailnet)
	if err != nil {
		return netip.Addr{}, false, err
	}
	if err := writeChanged(filepath.Join(directory, natFileName), address.String()); err != nil {
		return netip.Addr{}, false, err
	}
	return current, true, nil
}

// meshDialHint reports the internode dial direction this node publishes. A
// node that cannot be dialed directly (its observed join-path IP is not
// assigned locally, or it runs behind the WSL2 NAT guest address) dials out
// and expects no inbound connection.
func meshDialHint(state string) string {
	if _, natted, err := readNAT(ownerDirectory(state)); err == nil && natted {
		return dialOut
	}
	if wslNATAddress() != "" {
		return dialOut
	}
	return ""
}
