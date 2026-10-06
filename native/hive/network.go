// SPDX-License-Identifier: MIT

package hive

import (
	"context"
	"encoding/json"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/wippyai/bee/native/hive/invite"
)

type interfaceAddress struct {
	name    string
	address netip.Addr
}

// assignedInterfaceAddresses lists the routable unicast addresses of the
// interfaces that are up.
func assignedInterfaceAddresses() ([]interfaceAddress, error) {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil, err
	}
	var result []interfaceAddress
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addresses, err := iface.Addrs()
		if err != nil {
			return nil, err
		}
		for _, value := range addresses {
			network, ok := value.(*net.IPNet)
			if !ok {
				continue
			}
			if address, ok := netip.AddrFromSlice(network.IP); ok {
				address = address.Unmap()
				if address.IsGlobalUnicast() && !address.IsLinkLocalUnicast() {
					result = append(result, interfaceAddress{name: iface.Name, address: address})
				}
			}
		}
	}
	return result, nil
}

// tailscaleIdentity returns this machine's tailnet addresses and MagicDNS name
// when the tailscale command is installed and connected.
func tailscaleIdentity() ([]netip.Addr, string) {
	command, err := exec.LookPath("tailscale")
	if err != nil {
		command, err = exec.LookPath("tailscale.exe")
	}
	if err != nil {
		return nil, ""
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	data, err := exec.CommandContext(ctx, command, "status", "--json").Output()
	if err != nil || len(data) > 1<<20 {
		return nil, ""
	}
	var status struct {
		Self struct {
			DNSName      string   `json:"DNSName"`
			TailscaleIPs []string `json:"TailscaleIPs"`
		} `json:"Self"`
	}
	if json.Unmarshal(data, &status) != nil {
		return nil, ""
	}
	var addresses []netip.Addr
	for _, value := range status.Self.TailscaleIPs {
		if address, err := netip.ParseAddr(value); err == nil && address.IsGlobalUnicast() {
			addresses = append(addresses, address.Unmap())
		}
	}
	return addresses, strings.TrimSuffix(strings.ToLower(status.Self.DNSName), ".")
}

// tailnetPrefix is the carrier-grade NAT range Tailscale assigns IPv4
// addresses from.
var tailnetPrefix = netip.MustParsePrefix("100.64.0.0/10")

// tailnetAddress reports whether address belongs to a tailnet.
func tailnetAddress(address netip.Addr, tailnet []netip.Addr) bool {
	return slices.Contains(tailnet, address) || tailnetPrefix.Contains(address) ||
		netip.MustParsePrefix("fd7a:115c:a1e0::/48").Contains(address)
}

func virtualInterface(name string) bool {
	for _, prefix := range []string{"docker", "veth", "br-", "virbr", "vboxnet", "vmnet", "vEthernet"} {
		if strings.HasPrefix(strings.ToLower(name), strings.ToLower(prefix)) {
			return true
		}
	}
	return false
}

// selectJoinCandidates lists where a joiner can attempt the handshake: tailnet
// addresses and the MagicDNS name first, then LAN interfaces, then virtual
// ones. It is deterministic, deduplicated and bounded. A candidate says where
// to attempt TLS; the invite's fingerprint authenticates whoever answers.
func selectJoinCandidates(port uint16, assigned []interfaceAddress, tailnet []netip.Addr, magicDNS string) []invite.Candidate {
	result := make([]invite.Candidate, 0, invite.MaxCandidates+1)
	seen := map[string]bool{}
	add := func(kind, scope, endpoint string) {
		if len(result) > invite.MaxCandidates || seen[endpoint] {
			return
		}
		candidate := invite.Candidate{Kind: kind, Scope: scope, Endpoint: endpoint}
		if !candidate.Valid() {
			return
		}
		seen[endpoint] = true
		result = append(result, candidate)
	}
	endpoint := func(address netip.Addr) string { return netip.AddrPortFrom(address.Unmap(), port).String() }
	for _, item := range assigned {
		if tailnetAddress(item.address, tailnet) {
			add("tailnet", "tailnet", endpoint(item.address))
		}
	}
	if magicDNS != "" {
		add("magicdns", "tailnet", net.JoinHostPort(magicDNS, strconv.Itoa(int(port))))
	}
	for _, item := range assigned {
		if !tailnetAddress(item.address, tailnet) && !virtualInterface(item.name) {
			add("interface", "lan", endpoint(item.address))
		}
	}
	for _, item := range assigned {
		if !tailnetAddress(item.address, tailnet) && virtualInterface(item.name) {
			add("interface", "vm", endpoint(item.address))
		}
	}
	return result
}

var wslPrivate = netip.MustParsePrefix("172.16.0.0/12")

// wslNATGuest returns the address of this machine's default interface when it
// is a WSL2 guest behind the Windows NAT, which other machines cannot reach.
func wslNATGuest(assigned []interfaceAddress) (netip.Addr, bool) {
	release, err := os.ReadFile("/proc/sys/kernel/osrelease")
	if err != nil || !strings.Contains(strings.ToLower(string(release)), "microsoft-standard-wsl2") {
		return netip.Addr{}, false
	}
	route, err := os.ReadFile("/proc/net/route")
	if err != nil {
		return netip.Addr{}, false
	}
	var defaultInterface string
	for _, line := range strings.Split(string(route), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 3 && fields[1] == "00000000" {
			defaultInterface = fields[0]
			break
		}
	}
	for _, item := range assigned {
		if item.name == defaultInterface && wslPrivate.Contains(item.address) {
			return item.address, true
		}
	}
	return netip.Addr{}, false
}

const mirroredNetworking = `enable mirrored networking: in Windows PowerShell open %UserProfile%\.wslconfig and set

  [wsl2]
  networkingMode=mirrored

then run "wsl --shutdown" and start this WSL distribution again; or connect both machines through Tailscale`

// inviteNotice explains, when the invite offers no tailnet endpoint and this
// machine is a WSL2 NAT guest, why another machine will not reach it.
func inviteNotice(candidates []invite.Candidate, assigned []interfaceAddress) string {
	for _, candidate := range candidates {
		if candidate.Scope == "tailnet" {
			return ""
		}
	}
	if guest, ok := wslNATGuest(assigned); ok {
		return "This machine is a WSL2 guest behind the Windows NAT (" + guest.String() + "); other machines cannot reach it. To " + mirroredNetworking + ".\n"
	}
	return ""
}

// joinFailureAdvice explains a failed join from the endpoints the invite names.
func joinFailureAdvice(line invite.Invite) string {
	endpoints := append([]string{line.Address.String()}, endpointList(line.Candidates)...)
	advice := "No endpoint of the invite answered: " + strings.Join(endpoints, ", ") + ".\n" +
		"Check that the machine that created the invite is still running `bee hive invite`, that both machines share a network or Tailscale, and that a firewall allows TCP to those ports.\n"
	for _, endpoint := range endpoints {
		if path, err := netip.ParseAddrPort(endpoint); err == nil && wslPrivate.Contains(path.Addr()) {
			advice += "If " + path.Addr().String() + " is a WSL2 NAT guest, " + mirroredNetworking + ".\n"
			break
		}
	}
	return advice
}

func endpointList(candidates []invite.Candidate) []string {
	result := make([]string, 0, len(candidates))
	for _, candidate := range candidates {
		result = append(result, candidate.Endpoint)
	}
	return result
}
