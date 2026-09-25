// SPDX-License-Identifier: MIT

package launch

import (
	"fmt"
	"net/netip"
	"os"
	"strings"

	"github.com/wippyai/bee/native/hive/invite"
)

var wslPrivate = netip.MustParsePrefix("172.16.0.0/12")

func wslNAT(release, defaultInterface string, assigned []interfaceAddress) bool {
	if !strings.Contains(strings.ToLower(release), "microsoft-standard-wsl2") || defaultInterface != "eth0" {
		return false
	}
	for _, item := range assigned {
		if item.name == defaultInterface && wslPrivate.Contains(item.address) {
			return true
		}
	}
	return false
}

func linuxDefaultInterface() string {
	data, err := os.ReadFile("/proc/net/route")
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 3 && fields[1] == "00000000" {
			return fields[0]
		}
	}
	return ""
}

func wslNATAddress() string {
	release, err := os.ReadFile("/proc/sys/kernel/osrelease")
	if err != nil {
		return ""
	}
	assigned, err := assignedInterfaceAddresses()
	if err != nil {
		return ""
	}
	defaultInterface := linuxDefaultInterface()
	if !wslNAT(string(release), defaultInterface, assigned) {
		return ""
	}
	for _, item := range assigned {
		if item.name == defaultInterface && wslPrivate.Contains(item.address) {
			return item.address.String()
		}
	}
	return ""
}

func wslNATWarning(guest string, join, gossip, transport uint16) string {
	return fmt.Sprintf(`WSL2 NAT detected: the guest address %s is not reachable from other machines.
Start this owner with BEE_MESH_ADDRESS=%s and add the Windows host's reachable IP to BEE_HIVE_ADDRESSES before minting a new invite.
For a complete Hive path, enable mirrored networking in %%UserProfile%%\.wslconfig:
  [wsl2]
  networkingMode=mirrored
Then run "wsl --shutdown" in Windows PowerShell and restart Bee.
If using Windows forwarding instead, run PowerShell as Administrator:
  netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=%d connectaddress=%s connectport=%d
  netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=%d connectaddress=%s connectport=%d
  New-NetFirewallRule -DisplayName "Bee Hive TCP" -Direction Inbound -Action Allow -Protocol TCP -LocalPort %d,%d
  New-NetFirewallRule -DisplayName "Bee Hive UDP" -Direction Inbound -Action Allow -Protocol UDP -LocalPort %d
Windows portproxy forwards TCP only. Hive also uses UDP gossip on port %d; a UDP forwarder is required, so these TCP portproxy/firewall rules alone cannot complete the mesh.
`, guest, guest, join, guest, join, transport, guest, transport, join, transport, gossip, gossip)
}

func joinFailureAdvice(line invite.Invite) string {
	for _, candidate := range line.Candidates {
		path, err := netip.ParseAddrPort(candidate.Endpoint)
		if err != nil || !wslPrivate.Contains(path.Addr()) || candidate.Scope != "vm" {
			continue
		}
		return fmt.Sprintf("If %s is a WSL2 NAT guest, enable mirrored networking on its Windows host. For the invite TCP listener, run PowerShell as Administrator: netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=%d connectaddress=%s connectport=%d. Windows portproxy forwards TCP only; UDP gossip also needs forwarding. The inviter's `bee hive invite` output lists the other live ports.\n", path.Addr(), path.Port(), path.Addr(), path.Port())
	}
	return ""
}
