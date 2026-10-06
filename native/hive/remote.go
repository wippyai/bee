// SPDX-License-Identifier: MIT

package hive

import (
	"context"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	clusterapi "github.com/wippyai/runtime/api/cluster"
	"github.com/wippyai/runtime/api/event"
)

const (
	remoteDir = "remote"
	// maxRemote bounds the remembered addresses of other machines' nodes.
	maxRemote = 16
	clientTag = "bee-client-"
)

// rememberRemote records the gossip address of a node that runs on another
// machine, so a bee that starts later finds that machine even when the node
// named by the hive's seeds is gone. A node whose key this machine published,
// and an in-memory client, is not remembered.
func rememberRemote(dir string, node clusterapi.NodeInfo) error {
	name := string(node.ID)
	if node.Addr == "" || !strings.HasPrefix(name, nodePrefix) || strings.HasPrefix(name, clientTag) || strings.ContainsAny(name, `/\`) {
		return nil
	}
	if _, err := os.Stat(filepath.Join(dir, nodesDir, name+keySuffix)); err == nil {
		return nil
	}
	if err := writeFile(filepath.Join(dir, remoteDir, name+addressSuffix), []byte(node.Addr)); err != nil {
		return err
	}
	return pruneRemote(dir)
}

// pruneRemote keeps the maxRemote most recently written addresses.
func pruneRemote(dir string) error {
	entries, err := os.ReadDir(filepath.Join(dir, remoteDir))
	if err != nil {
		return err
	}
	type remembered struct {
		path string
		time int64
	}
	var files []remembered
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), addressSuffix) {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		files = append(files, remembered{filepath.Join(dir, remoteDir, entry.Name()), info.ModTime().UnixNano()})
	}
	sort.Slice(files, func(i, j int) bool { return files[i].time > files[j].time })
	for _, stale := range files[min(len(files), maxRemote):] {
		if err := removeFile(stale.path); err != nil {
			return err
		}
	}
	return nil
}

// remoteAddresses lists the remembered addresses of other machines' nodes.
func remoteAddresses(dir string) []string {
	entries, err := os.ReadDir(filepath.Join(dir, remoteDir))
	if err != nil {
		return nil
	}
	var addresses []string
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), addressSuffix) {
			continue
		}
		data, err := os.ReadFile(filepath.Join(dir, remoteDir, entry.Name()))
		if err == nil {
			if address := strings.TrimSpace(string(data)); address != "" {
				addresses = appendUnique(addresses, address)
			}
		}
	}
	return addresses
}

// remoteCache remembers the nodes the cluster reports.
type remoteCache struct {
	bus  event.Bus
	dir  string
	id   string
	stop context.CancelFunc
	done sync.WaitGroup
}

func startRemoteCache(ctx context.Context, bus event.Bus, dir string) (*remoteCache, error) {
	events := make(chan event.Event, 64)
	id, err := bus.Subscribe(ctx, clusterapi.System, events)
	if err != nil {
		return nil, err
	}
	loop, cancel := context.WithCancel(context.Background())
	cache := &remoteCache{bus: bus, dir: dir, id: id, stop: cancel}
	cache.done.Add(1)
	go func() {
		defer cache.done.Done()
		for {
			select {
			case <-loop.Done():
				return
			case item := <-events:
				if item.Kind != clusterapi.NodeJoined && item.Kind != clusterapi.NodeUpdated {
					continue
				}
				if data, ok := item.Data.(clusterapi.NodeEvent); ok {
					_ = rememberRemote(dir, data.Node)
				}
			}
		}
	}()
	return cache, nil
}

func (c *remoteCache) close() {
	c.bus.Unsubscribe(context.Background(), c.id)
	c.stop()
	c.done.Wait()
}
