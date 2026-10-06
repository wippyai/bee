// SPDX-License-Identifier: MIT

package hive

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	clusterapi "github.com/wippyai/runtime/api/cluster"
	app "github.com/wippyai/runtime/cmd/app"
)

func TestOnlyNetworkChangesRestartABee(t *testing.T) {
	applied := &Hive{Secret: "a", Advertise: "", Seeds: nil}
	require.False(t, networkChanged(applied, nil))
	require.False(t, networkChanged(applied, &Hive{Secret: "a", Machine: "m", Port: 31000}), "a machine name or port changes nothing running")
	require.False(t, networkChanged(applied, &Hive{Secret: "a", Seeds: []string{"192.0.2.1:31000"}}), "a new seed is not needed by a running bee")
	require.True(t, networkChanged(applied, &Hive{Secret: "b"}), "a hive with another secret")
	require.True(t, networkChanged(applied, &Hive{Secret: "a", Advertise: "192.0.2.1"}), "a machine that became reachable")
	require.True(t, networkChanged(nil, &Hive{Secret: "a"}), "a bee that started outside any hive")
}

func TestARunningBeeStopsAndRelaunchesWhenItsMachineJoinsAHive(t *testing.T) {
	dir := isolatedConfig(t)
	interrupted := make(chan struct{}, 1)
	watch := &hiveWatch{dir: dir, applied: nil, interval: 10 * time.Millisecond, interrupt: func() { interrupted <- struct{}{} }}
	host := &Host{watch: watch}
	var relaunched atomic.Int32
	host.relaunch = func() error { relaunched.Add(1); return nil }
	watch.start()
	defer watch.close()

	require.NoError(t, host.finish())
	require.Zero(t, relaunched.Load(), "a bee that is not asked to restart ends")

	_, err := Ensure(dir)
	require.NoError(t, err)
	select {
	case <-interrupted:
	case <-time.After(5 * time.Second):
		t.Fatal("the bee did not stop for the hive it was not started in")
	}
	require.NoError(t, host.finish())
	require.Equal(t, int32(1), relaunched.Load())
}

func TestARunningBeeKeepsRunningWhenOnlySeedsChange(t *testing.T) {
	dir := isolatedConfig(t)
	hive, err := Ensure(dir)
	require.NoError(t, err)
	interrupted := make(chan struct{}, 1)
	watch := &hiveWatch{dir: dir, applied: hive, interval: 10 * time.Millisecond, interrupt: func() { interrupted <- struct{}{} }}
	watch.start()
	defer watch.close()
	changed := *hive
	changed.Seeds = []string{"192.0.2.1:31000"}
	require.NoError(t, WriteHive(dir, changed))
	select {
	case <-interrupted:
		t.Fatal("a seed change stopped the bee")
	case <-time.After(300 * time.Millisecond):
	}
}

func TestRemoteNodesAreRememberedAsSeedsForLaterStarts(t *testing.T) {
	dir := isolatedConfig(t)
	hive, err := Ensure(dir)
	require.NoError(t, err)
	require.NoError(t, writeFile(filepath.Join(dir, nodesDir, "bee-local"+keySuffix), []byte("key")))

	for node, address := range map[string]string{"bee-local": "192.0.2.1:31000", "bee-remote": "192.0.2.9:32000", "bee-client-x": "192.0.2.9:32001", "stranger": "192.0.2.9:32002"} {
		require.NoError(t, rememberRemote(dir, clusterapi.NodeInfo{ID: clusterapi.NodeID(node), Addr: address}))
	}
	require.Equal(t, []string{"192.0.2.9:32000"}, remoteAddresses(dir), "only nodes of other machines are remembered")

	config, _, err := Prepare(dir, t.TempDir(), *hive, &Members{})
	require.NoError(t, err)
	require.Contains(t, config.Sub("cluster").GetString("membership.join_addrs", ""), "192.0.2.9:32000")
}

func TestRememberedAddressesAreBounded(t *testing.T) {
	dir := isolatedConfig(t)
	for index := 0; index < maxRemote+5; index++ {
		require.NoError(t, rememberRemote(dir, clusterapi.NodeInfo{ID: clusterapi.NodeID("bee-" + strconv.Itoa(index)), Addr: "192.0.2.9:" + strconv.Itoa(32000+index)}))
		old := time.Now().Add(time.Duration(index-100) * time.Second)
		require.NoError(t, os.Chtimes(filepath.Join(dir, remoteDir, "bee-"+strconv.Itoa(index)+addressSuffix), old, old))
	}
	require.NoError(t, pruneRemote(dir))
	require.Len(t, remoteAddresses(dir), maxRemote)
	require.NotContains(t, remoteAddresses(dir), "192.0.2.9:32000", "the oldest address goes first")
}

func TestABeeRestartsAsTheSameCommandWhenItStopsForAJoinedHive(t *testing.T) {
	dir := isolatedConfig(t)
	host := Component()
	plan, err := host.Plan(context.Background(), app.Launch{Command: "bee", State: t.TempDir(), Op: app.OpRun})
	require.NoError(t, err)
	_, release, err := plan.Prepare(context.Background())
	require.NoError(t, err)
	var relaunched atomic.Int32
	host.relaunch = func() error { relaunched.Add(1); return nil }
	host.watch.interrupt = func() {}
	host.watch.interval = 10 * time.Millisecond
	require.NoError(t, host.Start(context.Background()))
	_, err = Ensure(dir)
	require.NoError(t, err)
	require.Eventually(t, host.watch.restartRequested, 5*time.Second, 10*time.Millisecond)
	require.NoError(t, host.Stop(context.Background()))
	require.NoError(t, release())
	require.Equal(t, int32(1), relaunched.Load())
}
