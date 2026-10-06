// SPDX-License-Identifier: MIT

package hive

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"github.com/stretchr/testify/require"
	clusterapi "github.com/wippyai/runtime/api/cluster"
	ctxapi "github.com/wippyai/runtime/api/context"
	app "github.com/wippyai/runtime/cmd/app"
)

func isolatedConfig(t *testing.T) string {
	t.Helper()
	config := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", config)
	dir, err := Dir()
	require.NoError(t, err)
	require.Equal(t, filepath.Join(config, "bee", "hive"), dir)
	return dir
}

func TestInitCreatesTheHiveOnceAndKeepsIt(t *testing.T) {
	dir := isolatedConfig(t)
	require.NoError(t, Init(dir))
	first, err := ReadHive(dir)
	require.NoError(t, err)
	require.NotNil(t, first)
	secret, err := base64.StdEncoding.DecodeString(first.Secret)
	require.NoError(t, err)
	require.Len(t, secret, 32)
	info, err := os.Stat(filepath.Join(dir, hiveFile))
	require.NoError(t, err)
	require.Equal(t, os.FileMode(0o600), info.Mode().Perm())

	require.NoError(t, Init(dir))
	second, err := ReadHive(dir)
	require.NoError(t, err)
	require.Equal(t, first.Secret, second.Secret)
}

func TestPlanWithoutAHiveLeavesTheLaunchUnchanged(t *testing.T) {
	isolatedConfig(t)
	plan, err := Component().Plan(context.Background(), app.Launch{Command: "bee", State: t.TempDir()})
	require.NoError(t, err)
	require.Nil(t, plan.Run)
	require.Nil(t, plan.Prepare)
}

func TestPlanRoutesHiveCommands(t *testing.T) {
	dir := isolatedConfig(t)
	plan, err := Component().Plan(context.Background(), app.Launch{Command: "bee", Args: []string{"hive", "init"}})
	require.NoError(t, err)
	require.NotNil(t, plan.Run)
	require.NoError(t, plan.Run(context.Background()))
	hive, err := ReadHive(dir)
	require.NoError(t, err)
	require.NotNil(t, hive)

	_, err = Component().Plan(context.Background(), app.Launch{Command: "bee", Args: []string{"hive", "frobnicate"}})
	require.ErrorContains(t, err, "unknown command")
}

func TestPrepareKeepsOneIdentityPerFolder(t *testing.T) {
	dir := isolatedConfig(t)
	require.NoError(t, Init(dir))
	hive, err := ReadHive(dir)
	require.NoError(t, err)
	state := t.TempDir()

	_, first, err := Prepare(dir, state, *hive, &Members{})
	require.NoError(t, err)
	_, again, err := Prepare(dir, state, *hive, &Members{})
	require.NoError(t, err)
	require.Equal(t, first, again)

	_, other, err := Prepare(dir, t.TempDir(), *hive, &Members{})
	require.NoError(t, err)
	require.NotEqual(t, first, other)
}

func TestPrepareJoinsTheHive(t *testing.T) {
	dir := isolatedConfig(t)
	require.NoError(t, Init(dir))
	hive, err := ReadHive(dir)
	require.NoError(t, err)

	_, peer, err := Prepare(dir, t.TempDir(), *hive, &Members{})
	require.NoError(t, err)
	require.NoError(t, writeFile(filepath.Join(dir, nodesDir, peer+addressSuffix), []byte("127.0.0.1:40001")))

	state := t.TempDir()
	config, name, err := Prepare(dir, state, *hive, &Members{})
	require.NoError(t, err)
	cluster := config.Sub("cluster")
	require.True(t, cluster.GetBool("enabled", false))
	require.Equal(t, name, cluster.GetString("name", ""))
	require.Equal(t, name, config.Sub("relay").GetString("node_name", ""))
	require.False(t, cluster.GetBool("raft.enabled", true))
	require.Equal(t, "127.0.0.1", cluster.GetString("membership.bind_addr", ""))
	require.Equal(t, "127.0.0.1:40001", cluster.GetString("membership.join_addrs", ""))
	require.Equal(t, hive.Secret, cluster.GetString("membership.secret_key", ""))

	node, key, err := loadNode(state)
	require.NoError(t, err)
	require.Equal(t, name, node.Name)
	public := base64.StdEncoding.EncodeToString(key.Public().(ed25519.PublicKey))
	require.Equal(t, public, cluster.Sub("internode.trusted_peer_keys").GetString(name, ""))

	raw, ok := cluster.Get("internode.peer_key_source")
	require.True(t, ok)
	source, ok := raw.(clusterapi.PeerKeySource)
	require.True(t, ok)
	resolved, ok := source(clusterapi.NodeID(peer))
	require.True(t, ok, "a published hive node key resolves")
	require.Len(t, resolved, ed25519.PublicKeySize)
	for _, rejected := range []string{"", "../hive", "bee-unknown", "a/b"} {
		_, ok := source(clusterapi.NodeID(rejected))
		require.False(t, ok, rejected)
	}
}

type fakeMembership struct{ local clusterapi.NodeInfo }

func (m fakeMembership) Nodes() []clusterapi.NodeInfo   { return []clusterapi.NodeInfo{m.local} }
func (m fakeMembership) LocalNode() clusterapi.NodeInfo { return m.local }
func (m fakeMembership) UpdateMeta(map[string]string)   {}
func (m fakeMembership) Link(clusterapi.NodeID) (clusterapi.Link, bool) {
	return clusterapi.Link{}, false
}

func TestStartPublishesTheAddressAndStopWithdrawsIt(t *testing.T) {
	dir := isolatedConfig(t)
	host := &Host{dir: dir, node: "bee-node"}
	ctx := ctxapi.NewRootContext()
	clusterapi.WithMembership(ctx, fakeMembership{local: clusterapi.NodeInfo{ID: "bee-node", Addr: "127.0.0.1:40002"}})

	require.NoError(t, host.Start(ctx))
	data, err := os.ReadFile(filepath.Join(dir, nodesDir, "bee-node"+addressSuffix))
	require.NoError(t, err)
	require.Equal(t, "127.0.0.1:40002", string(data))

	require.NoError(t, host.Stop(ctx))
	_, err = os.Stat(filepath.Join(dir, nodesDir, "bee-node"+addressSuffix))
	require.ErrorIs(t, err, os.ErrNotExist)
}

func TestStartAndStopWithoutAHiveDoNothing(t *testing.T) {
	isolatedConfig(t)
	host := Component()
	require.NoError(t, host.Start(ctxapi.NewRootContext()))
	require.NoError(t, host.Stop(ctxapi.NewRootContext()))
}

// holdState takes the folder state lock the way a running bee holds it.
func holdState(t *testing.T, state string) {
	t.Helper()
	file, err := os.OpenFile(filepath.Join(state, "lock"), os.O_CREATE|os.O_RDWR, 0o600)
	require.NoError(t, err)
	require.NoError(t, syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB))
	t.Cleanup(func() { _ = file.Close() })
}

func TestAnOwnedFolderInAHiveStartsAnInMemoryClient(t *testing.T) {
	dir := isolatedConfig(t)
	require.NoError(t, Init(dir))
	hive, err := ReadHive(dir)
	require.NoError(t, err)
	state := t.TempDir()
	_, folderNode, err := Prepare(dir, state, *hive, &Members{})
	require.NoError(t, err)
	holdState(t, state)

	host := Component()
	plan, err := host.Plan(context.Background(), app.Launch{Command: "bee", State: state, Op: app.OpRun})
	require.NoError(t, err)
	require.True(t, plan.Transient)
	require.Equal(t, clientCommand, plan.Command)
	require.Equal(t, []string{folderNode}, plan.Args)

	before, err := os.ReadDir(state)
	require.NoError(t, err)
	t.Setenv(RoleVariable, "")
	config, release, err := plan.Prepare(context.Background())
	require.NoError(t, err)
	require.NoError(t, release())
	require.Equal(t, ClientRole, os.Getenv(RoleVariable), "the client tells the application it is a display only")
	after, err := os.ReadDir(state)
	require.NoError(t, err)
	require.Equal(t, len(before), len(after), "a client writes nothing into the folder's state")

	client := config.Sub("cluster").GetString("name", "")
	require.True(t, strings.HasPrefix(client, "bee-client-"), client)
	require.NotEqual(t, folderNode, client)
	require.FileExists(t, filepath.Join(dir, nodesDir, client+keySuffix))

	ctx := ctxapi.NewRootContext()
	clusterapi.WithMembership(ctx, fakeMembership{local: clusterapi.NodeInfo{ID: clusterapi.NodeID(client), Addr: "127.0.0.1:40003"}})
	require.NoError(t, host.Start(ctx))
	require.NoError(t, host.Stop(ctx))
	require.NoFileExists(t, filepath.Join(dir, nodesDir, client+keySuffix))
	require.NoFileExists(t, filepath.Join(dir, nodesDir, client+addressSuffix))
	require.FileExists(t, filepath.Join(dir, nodesDir, folderNode+keySuffix), "the folder node's key stays")
}

func TestAnExplicitClientNeedsAHive(t *testing.T) {
	isolatedConfig(t)
	_, err := Component().Plan(context.Background(), app.Launch{Command: "bee", State: t.TempDir(), Op: app.OpRun, Args: []string{"client"}})
	require.ErrorContains(t, err, "bee hive init")
}

func TestAnExplicitClientWithoutAFolderNodeShowsANodeOfTheHive(t *testing.T) {
	dir := isolatedConfig(t)
	require.NoError(t, Init(dir))
	plan, err := Component().Plan(context.Background(), app.Launch{Command: "bee", State: t.TempDir(), Op: app.OpRun, Args: []string{"client"}})
	require.NoError(t, err)
	require.Equal(t, clientCommand, plan.Command)
	require.Empty(t, plan.Args, "the display picks a node of the hive itself")
	require.True(t, plan.Transient, "a client keeps no state of its own")
}

func TestAnOwnedFolderOutsideAHiveExplainsWhy(t *testing.T) {
	isolatedConfig(t)
	state := t.TempDir()
	holdState(t, state)
	_, err := Component().Plan(context.Background(), app.Launch{Command: "bee", State: state, Op: app.OpRun})
	require.ErrorContains(t, err, "bee hive init")
}

func TestNodeRunsTheFolderNodeWithoutADisplay(t *testing.T) {
	dir := isolatedConfig(t)
	require.NoError(t, Init(dir))
	plan, err := Component().Plan(context.Background(), app.Launch{Command: "bee", State: t.TempDir(), Op: app.OpRun, Args: []string{"node"}})
	require.NoError(t, err)
	require.Equal(t, nodeCommand, plan.Command)
	require.Empty(t, plan.Args)
	require.False(t, plan.Transient)
	require.NotNil(t, plan.Prepare, "the headless node joins the hive")
}

func TestNodeOutsideAHiveRunsHeadless(t *testing.T) {
	isolatedConfig(t)
	plan, err := Component().Plan(context.Background(), app.Launch{Command: "bee", State: t.TempDir(), Op: app.OpRun, Args: []string{"node"}})
	require.NoError(t, err)
	require.Equal(t, nodeCommand, plan.Command)
	require.Empty(t, plan.Args)
	require.Nil(t, plan.Prepare)
}

func TestNodeInAnOwnedFolderIsRefused(t *testing.T) {
	dir := isolatedConfig(t)
	require.NoError(t, Init(dir))
	state := t.TempDir()
	holdState(t, state)
	_, err := Component().Plan(context.Background(), app.Launch{Command: "bee", State: state, Op: app.OpRun, Args: []string{"node"}})
	require.ErrorContains(t, err, "already running in this folder")
}

func TestHookPostRunsTheHookHelperWithoutSelectingAFolder(t *testing.T) {
	isolatedConfig(t)
	plan, err := Component().Plan(context.Background(), app.Launch{Command: "bee", State: t.TempDir(), Op: app.OpRun,
		Args: []string{"hook-post", "http://127.0.0.1:1/hook", "action", "TOKEN_ENV", "Stop"}})
	require.NoError(t, err)
	require.NotNil(t, plan.Run, "the hook helper runs directly")
	require.Nil(t, plan.Prepare, "a hook process boots no node")
	require.Empty(t, plan.Command)
}

func TestHookPostNamesItsArguments(t *testing.T) {
	isolatedConfig(t)
	_, err := Component().Plan(context.Background(), app.Launch{Command: "bee", State: t.TempDir(), Op: app.OpRun,
		Args: []string{"hook-post", "http://127.0.0.1:1/hook"}})
	require.ErrorContains(t, err, "ENDPOINT ACTION_ID TOKEN_ENV_OR_FILE EVENT")
}

func TestPlanOpensAnAppCommandOnTheRunningFolderNode(t *testing.T) {
	dir := isolatedConfig(t)
	require.NoError(t, Init(dir))
	hive, err := ReadHive(dir)
	require.NoError(t, err)
	state := t.TempDir()
	_, node, err := Prepare(dir, state, *hive, &Members{})
	require.NoError(t, err)
	holdState(t, state)

	plan, err := Component().Plan(context.Background(), app.Launch{Command: "bee", Op: app.OpRun, State: state,
		Args: []string{"claude", "--resume"}})
	require.NoError(t, err)
	require.Equal(t, clientCommand, plan.Command)
	require.Equal(t, []string{node, "claude", "--resume"}, plan.Args)
	require.True(t, plan.Transient)
}
