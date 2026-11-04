// SPDX-License-Identifier: MIT

package hive

import (
	"database/sql"

	"context"
	"crypto/ed25519"
	"encoding/base64"
	_ "github.com/rqlite/go-sqlite3"
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

func TestPlanWithoutAHiveJoinsNoClusterButWatchesForOne(t *testing.T) {
	isolatedConfig(t)
	update, err := Component().Plan(context.Background(), app.Launch{Command: "bee", State: t.TempDir(), Op: app.OpUpdate})
	require.NoError(t, err)
	require.Nil(t, update.Run)
	require.Nil(t, update.Prepare, "an operation other than running boots no node")

	host := Component()
	plan, err := host.Plan(context.Background(), app.Launch{Command: "bee", State: t.TempDir()})
	require.NoError(t, err)
	require.Nil(t, plan.Run)
	require.NotNil(t, plan.Prepare)
	config, _, err := plan.Prepare(context.Background())
	require.NoError(t, err)
	require.False(t, config.Sub("cluster").GetBool("enabled", false), "a machine outside a hive runs no cluster")
	require.NotNil(t, host.watch, "the bee watches for the hive its machine joins")
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

	_, first, err := Prepare(dir, state, hive, &Members{})
	require.NoError(t, err)
	_, again, err := Prepare(dir, state, hive, &Members{})
	require.NoError(t, err)
	require.Equal(t, first, again)

	_, other, err := Prepare(dir, t.TempDir(), hive, &Members{})
	require.NoError(t, err)
	require.NotEqual(t, first, other)
}

func TestPrepareJoinsTheHive(t *testing.T) {
	dir := isolatedConfig(t)
	require.NoError(t, Init(dir))
	hive, err := ReadHive(dir)
	require.NoError(t, err)

	_, peer, err := Prepare(dir, t.TempDir(), hive, &Members{})
	require.NoError(t, err)
	require.NoError(t, writeFile(filepath.Join(dir, nodesDir, peer+addressSuffix), []byte("127.0.0.1:40001")))

	state := t.TempDir()
	config, name, err := Prepare(dir, state, hive, &Members{})
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
	_, folderNode, err := Prepare(dir, state, hive, &Members{})
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
	require.NotNil(t, plan.Prepare)
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
	_, node, err := Prepare(dir, state, hive, &Members{})
	require.NoError(t, err)
	holdState(t, state)

	plan, err := Component().Plan(context.Background(), app.Launch{Command: "bee", Op: app.OpRun, State: state,
		Args: []string{"claude", "--resume"}})
	require.NoError(t, err)
	require.Equal(t, clientCommand, plan.Command)
	require.Equal(t, []string{node, "claude", "--resume"}, plan.Args)
	require.True(t, plan.Transient)
}

// runFolder prepares one node start of the folder whose state is at state and
// returns the relay node name the runtime boots under.
func runFolder(t *testing.T, state string) string {
	t.Helper()
	plan, err := Component().Plan(context.Background(), app.Launch{Command: "bee", State: state, Op: app.OpRun})
	require.NoError(t, err)
	require.NotNil(t, plan.Prepare)
	config, _, err := plan.Prepare(context.Background())
	require.NoError(t, err)
	return config.Sub("relay").GetString("node_name", "")
}

func TestAStandaloneFolderRunsUnderItsOwnStoredIdentity(t *testing.T) {
	isolatedConfig(t)
	state := t.TempDir()
	name := runFolder(t, state)
	require.True(t, isNodeName(name), name)
	node, _, err := loadNode(state)
	require.NoError(t, err)
	require.Equal(t, node.Name, name, "the identity lives in the folder's state")
	require.Equal(t, name, runFolder(t, state), "every start reuses it")
	require.NotEqual(t, name, runFolder(t, t.TempDir()), "each folder has its own")
}

func TestAMovedFolderKeepsItsIdentity(t *testing.T) {
	isolatedConfig(t)
	root := t.TempDir()
	state := filepath.Join(root, "before", ".bee")
	require.NoError(t, os.MkdirAll(state, 0o700))
	name := runFolder(t, state)
	moved := filepath.Join(root, "after")
	require.NoError(t, os.Rename(filepath.Join(root, "before"), moved))
	require.Equal(t, name, runFolder(t, filepath.Join(moved, ".bee")))
}

func TestHiveInitAndJoinKeepTheFolderIdentity(t *testing.T) {
	dir := isolatedConfig(t)
	state := t.TempDir()
	standalone := runFolder(t, state)
	require.NoError(t, Init(dir))
	plan, err := Component().Plan(context.Background(), app.Launch{Command: "bee", State: state, Op: app.OpRun})
	require.NoError(t, err)
	config, _, err := plan.Prepare(context.Background())
	require.NoError(t, err)
	require.Equal(t, standalone, config.Sub("relay").GetString("node_name", ""))
	require.Equal(t, standalone, config.Sub("cluster").GetString("name", ""), "the hive member is the same node")

	joined, err := ReadHive(dir)
	require.NoError(t, err)
	joined.Advertise, joined.Seeds = "127.0.0.1", []string{"127.0.0.1:40009"}
	require.NoError(t, WriteHive(dir, *joined))
	plan, err = Component().Plan(context.Background(), app.Launch{Command: "bee", State: state, Op: app.OpRun})
	require.NoError(t, err)
	config, _, err = plan.Prepare(context.Background())
	require.NoError(t, err)
	require.Equal(t, standalone, config.Sub("cluster").GetString("name", ""), "a joined machine keeps the node")
}

// writeAuthority records the node ids a folder's approvals authority was
// established under, the way the node writes them at every start.
func writeAuthority(t *testing.T, path string, rows map[string]string) {
	t.Helper()
	db, err := sql.Open("sqlite3", path)
	require.NoError(t, err)
	defer db.Close()
	_, err = db.Exec("CREATE TABLE bee_approval_authority (owner_node TEXT PRIMARY KEY, incarnation INTEGER NOT NULL, established_at TEXT NOT NULL)")
	require.NoError(t, err)
	for owner, at := range rows {
		_, err = db.Exec("INSERT INTO bee_approval_authority VALUES (?, 1, ?)", owner, at)
		require.NoError(t, err)
	}
}

func TestAFolderWithStateAdoptsTheIdItsRecordsUse(t *testing.T) {
	isolatedConfig(t)
	state := t.TempDir()
	database := filepath.Join(state, "bee.db")
	t.Setenv(databaseVariable, database)
	const previous = "793c2287-0ef9-5880-89ae-881bade4c960"
	writeAuthority(t, database, map[string]string{
		"0b7cd5e2-3a41-5c2e-9f00-2d4b8e6a1c37": "2026-10-01T10:00:00.000Z",
		previous:                               "2026-10-27T21:04:37.793Z",
	})
	require.Equal(t, previous, runFolder(t, state), "the folder keeps the id it last ran under")
	node, _, err := loadNode(state)
	require.NoError(t, err)
	require.Equal(t, previous, node.Name, "the adopted id is stored")

	require.NoError(t, os.Remove(database))
	writeAuthority(t, database, map[string]string{"bee-00000000000000000000000000000001": "2026-11-01T00:00:00.000Z"})
	require.Equal(t, previous, runFolder(t, state), "the stored identity is never derived again")
}

func TestAFolderWithoutRecordsGetsANewIdentity(t *testing.T) {
	isolatedConfig(t)
	for _, kind := range []string{"no database", "no authority table", "no authority rows"} {
		t.Run(kind, func(t *testing.T) {
			state := t.TempDir()
			database := filepath.Join(state, "bee.db")
			t.Setenv(databaseVariable, database)
			switch kind {
			case "no authority table":
				db, err := sql.Open("sqlite3", database)
				require.NoError(t, err)
				_, err = db.Exec("CREATE TABLE other (id TEXT)")
				require.NoError(t, err)
				require.NoError(t, db.Close())
			case "no authority rows":
				writeAuthority(t, database, nil)
			}
			name := runFolder(t, state)
			require.Regexp(t, `^bee-[0-9a-f]{32}$`, name)
		})
	}
}

func TestTheStoredIdentityOutranksTheRuntimeVariable(t *testing.T) {
	isolatedConfig(t)
	t.Setenv("WIPPY_NODE_ID", "793c2287-0ef9-5880-89ae-881bade4c960")
	state := t.TempDir()
	name := runFolder(t, state)
	require.Regexp(t, `^bee-[0-9a-f]{32}$`, name, "the relay node is named by the folder, not the variable")
}
