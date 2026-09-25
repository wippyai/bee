// SPDX-License-Identifier: MIT

package launch

import (
	"fmt"
	"io"
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

// wslNotice is informational: Bee needs no environment variable, no Windows
// port proxy and no firewall rule to reach a WSL2 NAT guest, because it
// advertises the address its inviter observed and dials out over the
// authenticated join path. What the runtime still needs is a UDP path for
// memberlist gossip in both directions; until the runtime carries gossip over
// the internode link, mirrored networking is the complete answer.
func wslNotice(guest string, join, gossip, transport uint16) string {
	return fmt.Sprintf(`WSL2 NAT guest %s: Bee needs no environment variable and no Windows port proxy.
Bee advertises the address its inviter observed and dials out over the authenticated join path,
so the join listener%s is reached without forwarding.
Still required by the runtime: memberlist gossip uses UDP in both directions on port %d. Until the
runtime carries gossip over the internode link, a NATed peer and its inviter can lose each other
after a probe interval. Mirrored networking removes that gap; in Windows PowerShell set
%%UserProfile%%\.wslconfig to:

  [wsl2]
  networkingMode=mirrored

then run "wsl --shutdown" and restart Bee. This is informational: nothing above
blocks the join or the internode path that already work today.
`, guest, wslPorts(join, transport), gossip)
}

// wslPorts renders the live TCP ports this invite exposed, or nothing when they
// are unknown.
func wslPorts(join, transport uint16) string {
	switch {
	case join != 0 && transport != 0:
		return fmt.Sprintf(" (join %d, internode %d)", join, transport)
	case join != 0:
		return fmt.Sprintf(" (join %d)", join)
	case transport != 0:
		return fmt.Sprintf(" (internode %d)", transport)
	}
	return ""
}

// joinFailureAdvice explains a failed join when a candidate looks like a WSL2
// NAT guest address. Bee itself needs no port proxy; the remaining runtime gap
// is UDP gossip, which mirrored networking removes.
func joinFailureAdvice(line invite.Invite) string {
	for _, candidate := range line.Candidates {
		path, err := netip.ParseAddrPort(candidate.Endpoint)
		if err != nil || !wslPrivate.Contains(path.Addr()) || candidate.Scope != "vm" {
			continue
		}
		return fmt.Sprintf("If %s is a WSL2 NAT guest, enable mirrored networking in %%UserProfile%%\\.wslconfig ([wsl2] networkingMode=mirrored), then run \"wsl --shutdown\" and restart Bee. Bee needs no port proxy and no environment variable; the runtime still needs a UDP path for gossip.\n", path.Addr())
	}
	return ""
}

// writeString writes value to out when it is non-empty.
func writeString(out io.Writer, value string) error {
	if value == "" {
		return nil
	}
	_, err := io.WriteString(out, value)
	return err
}
