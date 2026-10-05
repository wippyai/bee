//go:build meshclient

// SPDX-License-Identifier: MIT
package mesh

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/wippyai/bee/native/hive/rendezvous"
	metricscfg "github.com/wippyai/runtime/api/service/metrics"
	stackpkg "github.com/wippyai/runtime/cluster"
	"github.com/wippyai/runtime/service/metrics"
	"github.com/wippyai/runtime/system/eventbus"
	"github.com/wippyai/runtime/system/payload"
	"go.uber.org/zap"
)

type joinedFixture struct {
	owner  *stackpkg.Stack
	config JoinConfig
}

// newJoinedFixture starts a loopback owner that enrolled one client node.
func newJoinedFixture(t *testing.T, ctx context.Context) joinedFixture {
	t.Helper()
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		t.Fatal(err)
	}
	ownerPub, ownerKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	clientPub, clientKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	collector := metrics.NewCollector(metricscfg.Config{})
	t.Cleanup(func() { _ = collector.Close() })
	owner, err := stackpkg.AssembleStack(stackpkg.StackConfig{NodeName: "owner", Logger: zap.NewNop(), Bus: eventbus.NewBus(), Collector: collector,
		Transcoder: payload.NewTranscoder(), MembershipBindAddr: "127.0.0.1", MembershipAdvertise: "127.0.0.1", InternodeBindAddr: "127.0.0.1",
		SecretKey: base64.StdEncoding.EncodeToString(secret), InternodeIdentityKey: base64.RawStdEncoding.EncodeToString(ownerKey),
		InternodeTrustedPeerKeys: map[string]string{
			"owner":  base64.RawStdEncoding.EncodeToString(ownerPub),
			"client": base64.RawStdEncoding.EncodeToString(clientPub),
		}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = owner.Stop() })
	if err := owner.Start(ctx); err != nil {
		t.Fatal(err)
	}
	execution := strings.Repeat("c", 32)
	descriptor, err := rendezvous.Capture(owner.Membership.LocalNode(), execution)
	if err != nil {
		t.Fatal(err)
	}
	directory := filepath.Join(t.TempDir(), "owner")
	if err := os.Mkdir(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	store, err := rendezvous.New(directory)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Publish(ctx, descriptor); err != nil {
		t.Fatal(err)
	}
	enrollment, err := rendezvous.NewEnrollment(directory)
	if err != nil {
		t.Fatal(err)
	}
	if err := enrollment.Initialize(ctx, execution, secret); err != nil {
		t.Fatal(err)
	}
	if _, err := enrollment.Register(ctx, execution, "client", clientPub); err != nil {
		t.Fatal(err)
	}
	return joinedFixture{owner: owner, config: JoinConfig{Directory: directory, EnrollmentDirectory: directory, Node: "client", Key: clientKey}}
}

// A joined client's departure is part of the physical exit the user waits on:
// its graceful leave from the loopback mesh must complete promptly.
func TestJoinedClientLeavesPromptly(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	fixture := newJoinedFixture(t, ctx)
	var departed time.Time
	err := Joined(ctx, fixture.config, func(context.Context, *stackpkg.Stack, rendezvous.Descriptor) error {
		departed = time.Now()
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if elapsed := time.Since(departed); elapsed > 400*time.Millisecond {
		t.Fatalf("joined client took %v to leave the mesh", elapsed)
	}
}

// The owner's members see a joined client as a display client, never as a
// node holding workspaces.
func TestJoinedClientAdvertisesDisplayRole(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	fixture := newJoinedFixture(t, ctx)
	err := Joined(ctx, fixture.config, func(context.Context, *stackpkg.Stack, rendezvous.Descriptor) error {
		for _, member := range fixture.owner.Membership.Nodes() {
			if member.ID != "client" {
				continue
			}
			if role := member.Meta[RoleMetadata]; role != ClientRole {
				return fmt.Errorf("joined client advertises role %q", role)
			}
			return nil
		}
		return errors.New("owner does not list the joined client")
	})
	if err != nil {
		t.Fatal(err)
	}
}
