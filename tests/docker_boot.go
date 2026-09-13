// SPDX-License-Identifier: MIT
// Verifies the compiled Docker module through real boot, strict Lua typing and
// process admission. A private socket counts requests; no container is started.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"time"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	runtime := flag.String("runtime", "", "runtime with desktop and configured Docker factories")
	flag.Parse()
	if *runtime == "" {
		return fmt.Errorf("runtime is required")
	}
	root, err := os.MkdirTemp("", "bee-docker-boot-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	if err := os.Mkdir(filepath.Join(root, "src"), 0700); err != nil {
		return err
	}
	socket := filepath.Join(root, "daemon.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		return err
	}
	var requests atomic.Int32
	server := &http.Server{ReadHeaderTimeout: time.Second, Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		http.Error(w, "daemon access is unexpected", http.StatusServiceUnavailable)
	})}
	defer server.Close()
	go func() { _ = server.Serve(listener) }()
	host, _ := json.Marshal("unix://" + socket)
	files := map[string]string{
		"wippy.lock":  "directories:\n  src: src\n  modules: .wippy\n",
		".wippy.yaml": "version: '1.0'\nbee:\n  docker:\n    reference: fixture:docker\n    host: " + string(host) + "\n",
		"src/_index.yaml": `version: '1.0'
namespace: app
entries:
- name: terminal
  kind: terminal.host
  hide_logs: true
  lifecycle: {auto_start: true}
- name: check
  kind: process.lua
  source: file://check.lua
  method: main
  modules: [docker_pty]
  meta:
    command:
      name: check
      security:
        actor: {id: fixture}
        policies: [app:attach]
- name: attach
  kind: security.policy
  policy:
    actions: [docker.attach]
    resources: ['fixture:docker/` + strings.Repeat("a", 64) + `']
    effect: allow
`,
		"src/check.lua": `local docker = require("docker_pty")
local function main()
    local child, err = docker.attach({container_id=string.rep("a",64),
        image_id="sha256:"..string.rep("b",64), started_at="2026-09-13T10:00:00.123456789Z", labels={attempt="fixture"}})
    if not child then error(tostring(err)) end
    child:close(true)
    local denied, denial = docker.attach({container_id=string.rep("c",64),
        image_id="sha256:"..string.rep("b",64), started_at="2026-09-13T10:00:00.123456789Z", labels={attempt="fixture"}})
    if denied or not denial then error("unapproved container was accepted") end
    return true
end
return {main=main}
`,
	}
	for path, content := range files {
		if err := os.WriteFile(filepath.Join(root, path), []byte(content), 0600); err != nil {
			return err
		}
	}
	for _, configured := range []bool{true, false} {
		if !configured {
			if err := os.WriteFile(filepath.Join(root, ".wippy.yaml"), []byte("version: '1.0'\n"), 0600); err != nil {
				return err
			}
			script := `local docker = require("docker_pty")
local function main()
    local child, err = docker.attach({container_id=string.rep("a",64),
        image_id="sha256:"..string.rep("b",64), started_at="2026-09-13T10:00:00Z", labels={attempt="fixture"}})
    if child or not err or not string.find(tostring(err), "not configured", 1, true) then
        error("unconfigured Docker did not refuse attachment")
    end
    return true
end
return {main=main}
`
			if err := os.WriteFile(filepath.Join(root, "src/check.lua"), []byte(script), 0600); err != nil {
				return err
			}
		}
		for _, args := range [][]string{
			{"lint", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true"},
			{"run", "check"},
		} {
			ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
			command := exec.CommandContext(ctx, *runtime, args...)
			command.Dir = root
			command.Env = append(os.Environ(), "XDG_CONFIG_HOME="+filepath.Join(root, "config"), "DOCKER_HOST=://invalid")
			output, err := command.CombinedOutput()
			cancel()
			if err != nil {
				return fmt.Errorf("compiled Docker module %s (configured=%t): %w\n%s", args[0], configured, err, output)
			}
		}
	}
	if count := requests.Load(); count != 0 {
		return fmt.Errorf("boot/constructor/refusal contacted daemon %d times", count)
	}
	fmt.Println("PASS: configured/unconfigured Docker module boot, strict types, authorized handle and denied container; no daemon I/O")
	return nil
}
