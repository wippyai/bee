// SPDX-License-Identifier: MIT

package launch

import (
	"net/netip"
	"testing"
)

func TestGossipSeedUsesVerifiedJoinPath(t *testing.T) {
	for _, tc := range []struct{ gossip, path, want string }{
		{"127.0.0.1:4000", "192.168.1.5:5000", "192.168.1.5:4000"},
		{"[::1]:4000", "[fd7a:115c:a1e0::1]:5000", "[fd7a:115c:a1e0::1]:4000"},
		{"192.168.1.5:4000", "100.70.10.28:5000", "100.70.10.28:4000"},
		{"127.0.0.1:4000", "127.0.0.1:5000", "127.0.0.1:4000"},
	} {
		gossip, err := netip.ParseAddrPort(tc.gossip)
		if err != nil {
			t.Fatal(err)
		}
		if got := gossipSeedForPath(gossip, tc.path).String(); got != tc.want {
			t.Errorf("seed %s via %s = %s, want %s", tc.gossip, tc.path, got, tc.want)
		}
	}
}
