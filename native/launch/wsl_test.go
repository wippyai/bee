// SPDX-License-Identifier: MIT

package launch

import (
	"net/netip"
	"strings"
	"testing"

	"github.com/wippyai/bee/native/hive/invite"
)

func TestWSL2NATDetectionAndActionableWarning(t *testing.T) {
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
	message := wslNATWarning("172.24.10.5", 4101, 4102, 4103)
	for _, part := range []string{
		"mirrored networking", "portproxy", "TCP only", "UDP gossip",
		"listenport=4101 connectaddress=172.24.10.5 connectport=4101",
		"listenport=4103 connectaddress=172.24.10.5 connectport=4103",
		"-Protocol UDP -LocalPort 4102",
	} {
		if !strings.Contains(message, part) {
			t.Errorf("warning missing %q: %s", part, message)
		}
	}
}

func TestJoinFailureExplainsPrivateWSLHop(t *testing.T) {
	line := invite.Invite{Address: netip.MustParseAddrPort("127.0.0.1:4101"), Candidates: []invite.Candidate{{Kind: "interface", Scope: "vm", Endpoint: "172.24.10.5:4101"}}}
	message := joinFailureAdvice(line)
	for _, part := range []string{"mirrored networking", "portproxy", "172.24.10.5", "4101", "UDP gossip"} {
		if !strings.Contains(message, part) {
			t.Errorf("join advice missing %q: %s", part, message)
		}
	}
}
