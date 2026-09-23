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
