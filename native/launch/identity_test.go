// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"path/filepath"
	"testing"

	app "github.com/wippyai/runtime/cmd/app"
)

func TestStateNodeIdentityIsSharedAcrossRuntimeLaunches(t *testing.T) {
	t.Setenv("WIPPY_NODE_ID", "ordinary-runtime-node")
	state := filepath.Join(t.TempDir(), "state")
	directory := makeProject(t)
	host := newHost(systemHostResolver())
	owner, err := host.Plan(context.Background(), app.Launch{Op: app.OpRun, Command: desktopCommand,
		Args: []string{ownerArgument}, State: state, Dir: directory, Explicit: true})
	if err != nil {
		t.Fatal(err)
	}
	if owner.Prepare == nil {
		t.Fatal("owner plan has no Prepare")
	}
	ownerConfig, release, err := owner.Prepare(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	ownerNode := ownerConfig.Sub("cluster").GetString("name", "")
	if ownerNode == "" {
		t.Fatal("owner plan did not configure its node identity")
	}
	if ownerNode != "ordinary-runtime-node" {
		t.Fatalf("owner node = %q, want the ordinary runtime identity", ownerNode)
	}
	if err := release(); err != nil {
		t.Fatal(err)
	}

	application, err := host.Plan(context.Background(), app.Launch{Op: app.OpRun, Command: desktopCommand,
		Args: []string{"bee.resources:authority"}, State: state, Dir: makeProject(t), Explicit: true})
	if err != nil {
		t.Fatal(err)
	}
	if application.Prepare == nil {
		t.Fatal("direct application plan does not install the state node identity")
	}
	applicationConfig, release, err := application.Prepare(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = release() }()
	if got := applicationConfig.Sub("relay").GetString("node_name", ""); got != ownerNode {
		t.Fatalf("direct application node = %q, owner node = %q", got, ownerNode)
	}
	if got := applicationConfig.Sub("cluster").GetString("name", ""); got != ownerNode {
		t.Fatalf("direct application cluster node = %q, owner node = %q", got, ownerNode)
	}
}

func TestStateNodeIdentityPersistsLegacyAliasForStoreMigration(t *testing.T) {
	t.Setenv("WIPPY_NODE_ID", "ordinary-runtime-node")
	state := filepath.Join(t.TempDir(), "state")
	directory := makeProject(t)
	host := newHost(systemHostResolver())
	owner, err := host.Plan(context.Background(), app.Launch{Op: app.OpRun, Command: desktopCommand,
		Args: []string{ownerArgument}, State: state, Dir: directory, Explicit: true})
	if err != nil {
		t.Fatal(err)
	}
	config, release, err := owner.Prepare(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	ownerNode := config.Sub("cluster").GetString("name", "")
	identity, err := readStoredNodeIdentity(state)
	if err != nil {
		t.Fatal(err)
	}
	if identity.NodeID != "ordinary-runtime-node" {
		t.Fatalf("persisted runtime node id = %q", identity.NodeID)
	}
	if identity.LegacyNodeID != ownerNodeNameFromState(state) {
		t.Fatalf("persisted native migration alias = %q", identity.LegacyNodeID)
	}
	if err := release(); err != nil {
		t.Fatal(err)
	}

	application, err := host.Plan(context.Background(), app.Launch{Op: app.OpRun, Command: desktopCommand,
		Args: []string{"bee.resources:authority"}, State: state, Dir: directory, Explicit: true})
	if err != nil {
		t.Fatal(err)
	}
	if application.Prepare == nil {
		t.Fatal("direct application plan does not install the state node identity")
	}
	config, release, err = application.Prepare(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = release() }()
	if got := config.Sub("relay").GetString("node_name", ""); got != ownerNode {
		t.Fatalf("direct application node = %q, owner node = %q", got, ownerNode)
	}
}
