// SPDX-License-Identifier: MIT

package launch

import (
	"net/netip"
	"strings"
	"testing"

	"github.com/wippyai/bee/native/hive/invite"
)

func TestWSL2NATDetectionAndInformationalNotice(t *testing.T) {
	assigned := []interfaceAddress{{name: "eth0", address: netip.MustParseAddr("172.24.10.5")}}
	if !wslNAT("6.6.87.2-microsoft-standard-WSL2", "eth0", assigned) {
		t.Fatal("missed WSL2 NAT")
	}
	if wslNAT("6.6.87.2-microsoft-standard-WSL2", "eth2", assigned) {
		t.Fatal("mirrored interface identified as NAT")
	}
	if wslNAT("6.6.87.2-generic", "eth0", assigned) {
		t.Fatal("ordinary Linux identified as WSL")
	}
	message := wslNotice("172.24.10.5", 4101, 4102, 4103)
	for _, part := range []string{
		"needs no environment variable", "no Windows port proxy", "Mirrored networking",
		"gossip uses UDP in both directions on port 4102", "join 4101", "internode 4103",
		"informational",
	} {
		if !strings.Contains(message, part) {
			t.Errorf("notice missing %q: %s", part, message)
		}
	}
	// The old env-var and portproxy instructions are gone.
	for _, gone := range []string{"BEE_MESH_ADDRESS", "BEE_HIVE_ADDRESSES", "netsh interface portproxy", "New-NetFirewallRule"} {
		if strings.Contains(message, gone) {
			t.Errorf("notice still names %q: %s", gone, message)
		}
	}
}

func TestJoinFailureExplainsPrivateWSLHop(t *testing.T) {
	line := invite.Invite{Address: netip.MustParseAddrPort("127.0.0.1:4101"), Candidates: []invite.Candidate{{Kind: "interface", Scope: "vm", Endpoint: "172.24.10.5:4101"}}}
	message := joinFailureAdvice(line)
	for _, part := range []string{"mirrored networking", "172.24.10.5", "no port proxy", "UDP path for gossip"} {
		if !strings.Contains(message, part) {
			t.Errorf("join advice missing %q: %s", part, message)
		}
	}
}
