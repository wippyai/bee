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

// resolveAdvertiseAddress picks or reads the advertise address of state using
// the live interfaces and Tailscale identity.
func resolveAdvertiseAddress(state string) (netip.Addr, error) {
	assigned, err := assignedInterfaceAddresses()
	if err != nil {
		return netip.Addr{}, err
	}
	tailnet, _ := tailscaleIdentity()
	return ensureAdvertiseAddress(ownerDirectory(state), assigned, tailnet)
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
