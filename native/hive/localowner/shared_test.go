//go:build meshclient

// SPDX-License-Identifier: MIT
package localowner

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"os"
	"testing"
	"time"

	"github.com/wippyai/bee/native/hive/rendezvous"
	cluster "github.com/wippyai/runtime/api/cluster"
	"github.com/wippyai/runtime/api/security"
	app "github.com/wippyai/runtime/cmd/app"
)

func TestSharedProjectEnrollmentKeepsClientAuthorityLocal(t *testing.T) {
	ctx := context.Background()
	hiveDir := t.TempDir()
	if err := os.Chmod(hiveDir, 0700); err != nil {
		t.Fatal(err)
	}
	prepare := func() (*Component, app.OwnerResources) {
		t.Helper()
		owner, err := New(Options{Node: "Antares", Lifetime: time.Hour, HiveDirectory: hiveDir})
		if err != nil {
			t.Fatal(err)
		}
		state := t.TempDir()
		plan, err := owner.PrepareProjectOwner(ctx, app.LaunchRequest{StateDir: state, Directory: state})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() {
			if err := plan.Close(); err != nil {
				t.Error(err)
			}
		})
		return owner, plan
	}
	a, pa := prepare()
	b, pb := prepare()
	value := func(p app.OwnerResources, key string) interface{} {
		t.Helper()
		v, ok := p.Config.Get(key)
		if !ok {
			t.Fatalf("missing %s", key)
		}
		return v
	}
	if a.options.Node == b.options.Node {
		t.Fatal("project identities collide")
	}
	if value(pa, "cluster.membership.secret_key") != value(pb, "cluster.membership.secret_key") {
		t.Fatal("gossip keys differ")
	}
	ca, err := os.ReadFile(value(pa, "cluster.internode.tls.cert_file").(string))
	if err != nil {
		t.Fatal(err)
	}
	cb, err := os.ReadFile(value(pb, "cluster.internode.tls.cert_file").(string))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(ca, cb) {
		t.Fatal("projects reused a leaf certificate")
	}
	ka := value(pa, "cluster.internode.peer_key_source").(cluster.PeerKeySource)
	kb := value(pb, "cluster.internode.peer_key_source").(cluster.PeerKeySource)
	if _, ok := ka(b.options.Node); !ok {
		t.Fatal("A cannot resolve B")
	}
	if _, ok := kb(a.options.Node); !ok {
		t.Fatal("B cannot resolve A")
	}
	enrollment, err := rendezvous.NewEnrollment(a.state.directory)
	if err != nil {
		t.Fatal(err)
	}
	public, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	lease, _, err := enrollment.RegisterHeld(ctx, a.state.execution, "display-A", public)
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Close(ctx)
	actor := security.Actor{ID: "bee.hive.supervisor"}
	sender := "{display-A@bee.client:native|actor}"
	for _, check := range []struct {
		owner *Component
		want  security.Result
	}{{a, security.Allow}, {b, security.Deny}} {
		policy, err := check.owner.ClientPolicy()
		if err != nil {
			t.Fatal(err)
		}
		if got := policy.Evaluate(actor, ClientAction, sender, nil); got != check.want {
			t.Fatalf("client authority %v, want %v", got, check.want)
		}
	}
	if err := pa.Close(); err != nil {
		t.Fatal(err)
	}
	if _, ok := kb(a.options.Node); ok {
		t.Fatal("closed A remains enrolled")
	}
	if _, ok := kb(b.options.Node); !ok {
		t.Fatal("closing A removed B")
	}
}
