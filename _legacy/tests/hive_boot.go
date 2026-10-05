// SPDX-License-Identifier: MIT
// A disposable, multi-process acceptance check of the actual native boot path.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"embed"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

//go:embed fixtures/hive_boot/*
var fixture embed.FS

type event struct {
	node           int
	stage, address string
	err            error
}
type output struct {
	sync.Mutex
	data bytes.Buffer
}

func (b *output) Write(p []byte) (int, error) { b.Lock(); defer b.Unlock(); return b.data.Write(p) }
func (b *output) String() string              { b.Lock(); defer b.Unlock(); return b.data.String() }

func run() error {
	runtimePath := flag.String("runtime", ".wippy/bin/bee-wippy", "native toolchain")
	idle := flag.Duration("idle", 0, "Linux-only idle observation after convergence (up to 20s)")
	count := flag.Int("nodes", 20, "concurrent runtime processes")
	servers := flag.Int("servers", 3, "Raft server processes; remaining nodes are clients")
	bootstrap := flag.String("bootstrap", "single", "single initial server or simultaneous quorum bootstrap")
	flag.Parse()
	if *idle < 0 || *idle > 20*time.Second || (*idle > 0 && runtime.GOOS != "linux") {
		return fmt.Errorf("idle observation requires Linux and a duration between zero and 20s")
	}
	if *count < 2 || *count > 100 {
		return fmt.Errorf("nodes must be between 2 and 100")
	}
	if *servers < 0 || *servers > *count {
		return fmt.Errorf("servers must be between zero and nodes")
	}
	if *bootstrap != "single" && *bootstrap != "quorum" {
		return fmt.Errorf("bootstrap must be single or quorum")
	}
	binary, err := filepath.Abs(*runtimePath)
	if err != nil {
		return err
	}
	root, err := os.MkdirTemp("", "bee-hive-boot-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	var running sync.WaitGroup
	defer func() { cancel(); running.Wait() }()
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return err
	}
	keys := make([]string, *count)
	trusted := make(map[string]string, *count)
	for i := range keys {
		pub, key, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			return err
		}
		keys[i] = base64.RawStdEncoding.EncodeToString(key)
		trusted[fmt.Sprintf("project-%d", i)] = base64.RawStdEncoding.EncodeToString(pub)
	}
	events := make(chan event, *count*5)
	var pids []int
	start := func(i int, seed string) error {
		role := "client"
		if i < *servers {
			role = "server"
		}
		expect := *servers
		if *bootstrap == "single" {
			expect = 0
			if i == 0 && role == "server" {
				expect = 1
			}
		}
		folder := filepath.Join(root, strconv.Itoa(i))
		if err := os.MkdirAll(filepath.Join(folder, "src"), 0700); err != nil {
			return err
		}
		for _, name := range []string{"_index.yaml", "main.lua"} {
			data, err := fixture.ReadFile("fixtures/hive_boot/" + name)
			if err != nil {
				return err
			}
			if err := os.WriteFile(filepath.Join(folder, "src", name), data, 0600); err != nil {
				return err
			}
		}
		if err := os.WriteFile(filepath.Join(folder, "wippy.lock"), []byte("directories:\n  modules: .wippy\n  src: ./src\n"), 0600); err != nil {
			return err
		}
		config := map[string]any{
			"version": "1.0", "shutdown": map[string]any{"timeout": "2s"},
			"relay": map[string]any{"node_name": fmt.Sprintf("project-%d", i)},
			"lua":   map[string]any{"type_system": map[string]any{"enabled": true, "strict": true}},
			"cluster": map[string]any{
				"enabled": true, "name": fmt.Sprintf("project-%d", i),
				"raft": map[string]any{"role": role, "bootstrap_expect": expect, "max_voters": *servers,
					"max_standbys": 0, "data_dir": filepath.Join(folder, "node-state")},
				"membership": map[string]any{"bind_addr": "127.0.0.1", "bind_port": 0, "join_addrs": seed,
					"secret_key": base64.StdEncoding.EncodeToString(secret)},
				"internode": map[string]any{"bind_addr": "127.0.0.1", "bind_port": 0, "auto_port": true,
					"identity_key": keys[i], "trusted_peer_keys": trusted},
			},
		}
		data, err := json.Marshal(config)
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(folder, ".wippy.yaml"), data, 0600); err != nil {
			return err
		}
		cmd := exec.CommandContext(ctx, binary, "run", "--silent", "hive-boot-probe", "--", strconv.Itoa(*count), role)
		cmd.Dir = folder
		cmd.Env = append(os.Environ(), "GOMAXPROCS=2")
		stdout, err := cmd.StdoutPipe()
		if err != nil {
			return err
		}
		stderr := &output{}
		cmd.Stderr = stderr
		if err := cmd.Start(); err != nil {
			_ = stdout.Close()
			return err
		}
		pids = append(pids, cmd.Process.Pid)
		running.Go(func() {
			scanner := bufio.NewScanner(stdout)
			for scanner.Scan() {
				line := scanner.Text()
				_, marker, ok := strings.Cut(line, "BEE_HIVE_PROBE ")
				if !ok {
					_, _ = stderr.Write([]byte(line + "\n"))
					continue
				}
				fields := strings.Fields(marker)
				if len(fields) == 2 {
					events <- event{node: i, stage: fields[0], address: fields[1]}
				}
			}
			scanErr := scanner.Err()
			waitErr := cmd.Wait()
			if ctx.Err() == nil {
				events <- event{node: i, err: fmt.Errorf("node exited before acceptance: scan=%v exit=%v\n%s", scanErr, waitErr, stderr.String())}
			}
		})
		return nil
	}
	if err := start(0, ""); err != nil {
		return err
	}
	seed := ""
	select {
	case first := <-events:
		if first.err != nil {
			return first.err
		}
		if first.stage != "ready" {
			return fmt.Errorf("seed did not report readiness")
		}
		seed = first.address
	case <-ctx.Done():
		return fmt.Errorf("seed startup: %w", ctx.Err())
	}
	for i := 1; i < *count; i++ {
		if err := start(i, seed); err != nil {
			return err
		}
	}
	ready := map[string]bool{seed: true}
	formed := make(map[int]bool)
	leaders := make(map[int]string)
	for len(formed) != *count {
		select {
		case event := <-events:
			if event.err != nil {
				return fmt.Errorf("node %d: %w", event.node, event.err)
			}
			switch event.stage {
			case "ready":
				if ready[event.address] {
					return fmt.Errorf("duplicate membership endpoint %s", event.address)
				}
				ready[event.address] = true
			case "formed":
				formed[event.node] = true
			case "leader":
				leaders[event.node] = event.address
			default:
				return fmt.Errorf("unknown probe event %q", event.stage)
			}
		case <-ctx.Done():
			return fmt.Errorf("cluster startup: %d/%d formed: %w", len(formed), *count, ctx.Err())
		}
	}
	if len(ready) != *count {
		return fmt.Errorf("missing node readiness")
	}
	if len(leaders) != *servers {
		return fmt.Errorf("missing server leadership observations")
	}
	leader := ""
	for _, selected := range leaders {
		if leader != "" && leader != selected {
			return fmt.Errorf("servers disagree on leader")
		}
		leader = selected
	}
	fmt.Printf("Hive boot: %d independent runtimes (%d Raft servers), automatic gossip/internode ports, isolated state, strict Lua, converged membership and leadership\n", *count, *servers)
	if *idle > 0 {
		before, _, err := observeProcesses(pids)
		if err != nil {
			return err
		}
		started := time.Now()
		timer := time.NewTimer(*idle)
		defer timer.Stop()
		select {
		case e := <-events:
			return fmt.Errorf("unexpected event during idle observation: node=%d stage=%s error=%v", e.node, e.stage, e.err)
		case <-ctx.Done():
			return ctx.Err()
		case <-timer.C:
		}
		after, sockets, err := observeProcesses(pids)
		if err != nil {
			return err
		}
		if after < before {
			return fmt.Errorf("process CPU counter regressed")
		}
		fmt.Printf("Hive idle observation: elapsed=%s aggregate_cpu_ticks=%d socket_descriptors=%d across %d owned processes; socket count includes listeners and UDP, not just peer connections; traffic bytes not measured\n", time.Since(started).Round(time.Millisecond), after-before, sockets, len(pids))
	}
	return nil
}

// Linux observations are deliberately reported in kernel clock ticks, without
// assuming a host CLK_TCK value. Only this fixture's child processes are read.
func observeProcesses(pids []int) (uint64, int, error) {
	var ticks uint64
	sockets := 0
	for _, pid := range pids {
		root := filepath.Join("/proc", strconv.Itoa(pid))
		data, err := os.ReadFile(filepath.Join(root, "stat"))
		if err != nil {
			return 0, 0, err
		}
		end := strings.LastIndexByte(string(data), ')')
		if end < 0 {
			return 0, 0, fmt.Errorf("invalid process stat for %d", pid)
		}
		fields := strings.Fields(string(data[end+1:]))
		if len(fields) < 13 {
			return 0, 0, fmt.Errorf("short process stat for %d", pid)
		}
		for _, field := range fields[11:13] {
			value, err := strconv.ParseUint(field, 10, 64)
			if err != nil {
				return 0, 0, err
			}
			ticks += value
		}
		fds, err := os.ReadDir(filepath.Join(root, "fd"))
		if err != nil {
			return 0, 0, err
		}
		for _, fd := range fds {
			target, err := os.Readlink(filepath.Join(root, "fd", fd.Name()))
			if os.IsNotExist(err) {
				continue
			} // Descriptor closed during observation.
			if err != nil {
				return 0, 0, err
			}
			if strings.HasPrefix(target, "socket:[") {
				sockets++
			}
		}
	}
	return ticks, sockets, nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
