// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"

	clusterapi "github.com/wippyai/runtime/api/cluster"
	app "github.com/wippyai/runtime/cmd/app"
)

// ownerLaunch is the public owner route: `bee --state <state> start`. The host
// plans it, so Prepare is attached exactly where the runtime calls it.
func ownerLaunch(state string) app.Launch {
	return app.Launch{Op: app.OpRun, Command: desktopCommand, Args: []string{ownerArgument},
		State: state, Dir: state, Explicit: true}
}

func TestPrepareOwnerBuildsClusterSection(t *testing.T) {
	state := t.TempDir()
	host, err := newHost(filepath.Join(state, "default"), systemHostResolver())
	if err != nil {
		t.Fatal(err)
	}
	plan, err := host.Plan(context.Background(), ownerLaunch(state))
	if err != nil {
		t.Fatal(err)
	}
	if plan.Prepare == nil {
		t.Fatal("owner plan has no Prepare")
	}
	config, release, err := plan.Prepare(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if release == nil {
		t.Fatal("owner preparation returned no release")
	}
	defer func() { _ = release() }()

	cluster := config.Sub("cluster")
	if !cluster.GetBool("enabled", false) {
		t.Fatal("cluster is not enabled")
	}
	if cluster.GetString("name", "") == "" {
		t.Fatal("cluster has no node name")
	}
	for key, want := range map[string]string{
		"membership.bind_addr": "127.0.0.1",
		"internode.bind_addr":  "127.0.0.1",
	} {
		if got := cluster.GetString(key, ""); got != want {
			t.Fatalf("%s = %q, want %q", key, got, want)
		}
	}
	if !cluster.GetBool("internode.auto_port", false) {
		t.Fatal("internode.auto_port is not enabled")
	}
	if cluster.GetString("internode.peer_key_source", "") != "" {
		t.Fatal("peer_key_source was serialized instead of bound as a native value")
	}
	source, present := cluster.Get("internode.peer_key_source")
	if !present {
		t.Fatal("cluster is missing internode.peer_key_source")
	}
	peerKey, ok := source.(clusterapi.PeerKeySource)
	if !ok {
		t.Fatalf("peer_key_source type = %T", source)
	}
	if _, found := peerKey("client-none"); found {
		t.Fatal("peer_key_source authorized an unenrolled node")
	}

	// State-owned credentials live under the state directory at owner-only modes.
	for key, mode := range map[string]os.FileMode{
		"membership.secret_file":      0o600,
		"internode.identity_key_file": 0o600,
	} {
		path := cluster.GetString(key, "")
		if !filepath.IsAbs(path) || !strings.HasPrefix(path, state+string(filepath.Separator)) {
			t.Fatalf("%s = %q, want a path under %q", key, path, state)
		}
		info, err := os.Stat(path)
		if err != nil {
			t.Fatalf("%s: %v", key, err)
		}
		if info.Mode().Perm() != mode {
			t.Fatalf("%s mode = %o, want %o", key, info.Mode().Perm(), mode)
		}
	}

	// The desktop bridge is enabled for the retained window application and
	// admits local clients without pre-listing node identities.
	desktop, present := config.Get("override.bee.hive.host:supervisor_service.input.desktop")
	if !present {
		t.Fatal("desktop bridge override is missing")
	}
	bridge, ok := desktop.(map[string]any)
	if !ok {
		t.Fatalf("desktop override type = %T", desktop)
	}
	if bridge["local_clients"] != true {
		t.Fatalf("desktop local_clients = %v", bridge["local_clients"])
	}
	if bridge["application"] != "bee.harness.window:app" {
		t.Fatalf("desktop application = %v", bridge["application"])
	}
	if execution, _ := bridge["execution"].(string); len(execution) != 32 {
		t.Fatalf("desktop execution = %v", bridge["execution"])
	}
}

func TestPrepareOwnerIsIdempotentAcrossRuns(t *testing.T) {
	state := t.TempDir()
	host, err := newHost(filepath.Join(state, "default"), systemHostResolver())
	if err != nil {
		t.Fatal(err)
	}
	prepare := func() (string, string) {
		plan, err := host.Plan(context.Background(), ownerLaunch(state))
		if err != nil {
			t.Fatal(err)
		}
		config, release, err := plan.Prepare(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = release() }()
		cluster := config.Sub("cluster")
		return cluster.GetString("membership.secret_file", ""), cluster.GetString("internode.identity_key_file", "")
	}
	firstSecret, firstKey := prepare()
	secondSecret, secondKey := prepare()
	if firstSecret != secondSecret || firstKey != secondKey {
		t.Fatalf("owner credentials changed between runs: %q/%q vs %q/%q", firstSecret, firstKey, secondSecret, secondKey)
	}
	secret, err := os.ReadFile(firstSecret)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(secret))); err != nil {
		t.Fatalf("membership secret is not base64: %v", err)
	}
	key, err := os.ReadFile(firstKey)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(key))); err != nil {
		t.Fatalf("internode identity key is not base64: %v", err)
	}
}

func TestTrustedClientKeysResolveThroughPeerKeySource(t *testing.T) {
	state := t.TempDir()
	host, err := newHost(filepath.Join(state, "default"), systemHostResolver())
	if err != nil {
		t.Fatal(err)
	}
	plan, err := host.Plan(context.Background(), ownerLaunch(state))
	if err != nil {
		t.Fatal(err)
	}
	config, release, err := plan.Prepare(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = release() }()
	source, _ := config.Sub("cluster").Get("internode.peer_key_source")
	peerKey, ok := source.(clusterapi.PeerKeySource)
	if !ok {
		t.Fatalf("peer_key_source type = %T", source)
	}
	if _, found := peerKey("client-unknown"); found {
		t.Fatal("peer_key_source authorized an unenrolled node")
	}
	public, _, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	trusted := ownerTrustedDirectory(state)
	if err := os.MkdirAll(trusted, 0o700); err != nil {
		t.Fatal(err)
	}
	encoded := base64.RawStdEncoding.EncodeToString(public)
	if err := os.WriteFile(filepath.Join(trusted, "client-1.pub"), []byte(encoded+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	got, found := peerKey("client-1")
	if !found || !public.Equal(got) {
		t.Fatalf("peer_key_source did not resolve an enrolled key: %v %v", found, got)
	}
	_ = netip.Addr{}
}
