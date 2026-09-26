// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/netip"
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
			if network, ok := value.(*net.IPNet); ok {
				if address, ok := netip.AddrFromSlice(network.IP); ok {
					address = address.Unmap()
					if address.IsGlobalUnicast() && !address.IsLinkLocalUnicast() {
						result = append(result, interfaceAddress{name: iface.Name, address: address})
					}
				}
			}
		}
	}
	return result, nil
}

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
	if err != nil || len(data) > 64*1024 {
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

func virtualInterface(name string) bool {
	for _, prefix := range []string{"docker", "veth", "br-", "virbr", "vboxnet", "vmnet"} {
		if strings.HasPrefix(strings.ToLower(name), prefix) {
			return true
		}
	}
	return false
}

// selectJoinCandidates is deterministic, deduplicated and bounded. A candidate
// says where to attempt TLS; it never grants authority or asserts reachability.
func selectJoinCandidates(primary netip.AddrPort, assigned []interfaceAddress, tailnet []netip.Addr, magicDNS string) []invite.Candidate {
	result := make([]invite.Candidate, 0, invite.MaxCandidates)
	seen := map[string]bool{primary.String(): true}
	add := func(kind, scope, endpoint string) {
		if len(result) >= invite.MaxCandidates || seen[endpoint] {
			return
		}
		candidate := invite.Candidate{Kind: kind, Scope: scope, Endpoint: endpoint}
		if !candidate.Valid() {
			return
		}
		seen[endpoint] = true
		result = append(result, candidate)
	}
	port := primary.Port()
	endpoint := func(address netip.Addr) string { return netip.AddrPortFrom(address.Unmap(), port).String() }
	for _, address := range tailnet {
		if slices.ContainsFunc(assigned, func(item interfaceAddress) bool { return item.address == address }) {
			add("tailnet", "tailnet", endpoint(address))
		}
	}
	if magicDNS != "" {
		add("magicdns", "tailnet", net.JoinHostPort(magicDNS, strconv.Itoa(int(port))))
	}
	for _, item := range assigned {
		if slices.Contains(tailnet, item.address) {
			continue
		}
		if virtualInterface(item.name) {
			continue
		}
		add("interface", "lan", endpoint(item.address))
	}
	for _, item := range assigned {
		if virtualInterface(item.name) {
			add("interface", "vm", endpoint(item.address))
		}
	}
	return result
}

func joinCandidates(primary netip.AddrPort) ([]invite.Candidate, error) {
	assigned, err := assignedInterfaceAddresses()
	if err != nil {
		return nil, fmt.Errorf("inspect network interfaces: %w", err)
	}
	tailnet, magicDNS := tailscaleIdentity()
	return selectJoinCandidates(primary, assigned, tailnet, magicDNS), nil
}

func meshCertificateAddresses(selected netip.Addr, assigned []interfaceAddress) []netip.Addr {
	result := []netip.Addr{selected}
	add := func(address netip.Addr) {
		address = address.Unmap()
		if len(result) < maxJoinAddresses && address.IsValid() && address.Zone() == "" && !address.IsUnspecified() && !slices.Contains(result, address) {
			result = append(result, address)
		}
	}
	for _, item := range assigned {
		if !virtualInterface(item.name) {
			add(item.address)
		}
	}
	for _, item := range assigned {
		if virtualInterface(item.name) {
			add(item.address)
		}
	}
	return result
}

func selectedMeshCertificateAddresses(selected netip.Addr) ([]netip.Addr, error) {
	assigned, err := assignedInterfaceAddresses()
	if err != nil {
		return nil, err
	}
	return meshCertificateAddresses(selected, assigned), nil
}
