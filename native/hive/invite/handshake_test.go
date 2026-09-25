// SPDX-License-Identifier: MIT

package invite

import (
	"context"
	"crypto/ed25519"
	"errors"
	"strings"
	"testing"
	"time"
)

// A decision bounded by its own deadline is still delivered within the
// connection's deadline, even when the handler waited for all of it.
func TestHandlerDeadlineLeavesTimeForTheAnswer(t *testing.T) {
	hive := identity(t)
	address := listen(t, hive, func(ctx context.Context, _ ed25519.PublicKey, _ Request) (Admission, *Refused) {
		<-ctx.Done()
		return Admission{}, &Refused{Code: "UNAVAILABLE", Message: "no decision in time"}
	})
	_, _, err := Dial(context.Background(), sample(address, hive), identity(t), Request{Node: "bee-owner-joiner"})
	var refused *Refused
	if !errors.As(err, &refused) || refused.Code != "UNAVAILABLE" {
		t.Fatalf("dial = %v", err)
	}
}

func TestDialReceivesALargeAdmissionAfterASlowRedemption(t *testing.T) {
	hive := identity(t)
	address := listen(t, hive, func(context.Context, ed25519.PublicKey, Request) (Admission, *Refused) {
		time.Sleep(300 * time.Millisecond)
		return Admission{Node: "bee-owner-0123456789abcdef", Certificate: strings.Repeat("c", 3000), Authorities: strings.Repeat("a", 3000)}, nil
	})
	admission, _, err := Dial(context.Background(), sample(address, hive), identity(t), Request{Node: "bee-owner-joiner"})
	if err != nil || len(admission.Certificate) != 3000 {
		t.Fatalf("dial = %v", err)
	}
}

// The listener states where the joiner connected from, from the accepted
// socket alone, and the joiner receives it in the admission. A value the wire
// claimed is discarded.
func TestListenerReportsTheObservedJoinAddress(t *testing.T) {
	hive := identity(t)
	var observed string
	address := listen(t, hive, func(_ context.Context, _ ed25519.PublicKey, request Request) (Admission, *Refused) {
		observed = request.Observed
		return Admission{Node: "bee-owner-0123456789abcdef"}, nil
	})
	admission, _, err := Dial(context.Background(), sample(address, hive), identity(t),
		Request{Node: "bee-owner-joiner", Observed: "203.0.113.9"})
	if err != nil {
		t.Fatal(err)
	}
	if observed != "127.0.0.1" {
		t.Fatalf("listener observed %q, want the accepted socket's 127.0.0.1", observed)
	}
	if admission.Observed != "127.0.0.1" {
		t.Fatalf("admission observed %q, want 127.0.0.1", admission.Observed)
	}
}

// An admission's observed address is validated before it is trusted: an
// absent value is allowed for an older hive node, a bare IP literal is
// allowed, and anything else is refused.
func TestValidObservedAcceptsOnlyBareIPLiterals(t *testing.T) {
	for value, want := range map[string]bool{
		"": true, "127.0.0.1": true, "192.168.1.4": true, "fd7a:115c:a1e0::1": true,
		"0.0.0.0": false, "not-an-ip": false, "192.168.1.4%eth0": false, "127.0.0.1:4100": false,
	} {
		if got := validObserved(value); got != want {
			t.Errorf("validObserved(%q) = %v, want %v", value, got, want)
		}
	}
}

// An admission without an observed address is still accepted, so an older
// hive node keeps working.
func TestDialAcceptsAnAdmissionWithoutAnObservedAddress(t *testing.T) {
	hive := identity(t)
	address := listen(t, hive, func(context.Context, ed25519.PublicKey, Request) (Admission, *Refused) {
		return Admission{Node: "bee-owner-0123456789abcdef"}, nil
	})
	if _, _, err := Dial(context.Background(), sample(address, hive), identity(t), Request{Node: "bee-owner-joiner"}); err != nil {
		t.Fatal(err)
	}
}
