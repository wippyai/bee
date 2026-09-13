// SPDX-License-Identifier: MIT
// Component-boundary proof using the actual Lua Docker client and a private
// fake daemon. It does not create a container or prove managed Agent launch.
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
	"reflect"
	"strings"
	"sync"
	"time"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func run() error {
	runtime := flag.String("runtime", "", "selected Bee runtime executable")
	dockerSource := flag.String("docker-source", "", "reviewed userspace Docker component directory")
	flag.Parse()
	if *runtime == "" || *dockerSource == "" {
		return fmt.Errorf("runtime and docker-source are required")
	}
	root, err := os.MkdirTemp("", "bee-docker-configuration-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	source := filepath.Join(root, "src")
	if err := os.Mkdir(source, 0700); err != nil {
		return err
	}
	for target, origin := range map[string]string{
		"configuration.lua": "src/placement/docker/configuration.lua",
		"bounds.lua":        "src/threads/records/bounds.lua",
		"client.lua":        filepath.Join(*dockerSource, "client.lua"),
	} {
		data, err := os.ReadFile(origin)
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(source, target), data, 0600); err != nil {
			return err
		}
	}
	socket := filepath.Join(root, "daemon.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		return err
	}
	var mu sync.Mutex
	calls := []string{}
	problems := []string{}
	server := &http.Server{ReadHeaderTimeout: 5 * time.Second, Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		calls = append(calls, r.Method+" "+r.URL.Path)
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == "GET" && r.URL.Path == "/_ping":
			_, _ = w.Write([]byte("{}"))
		case r.Method == "POST" && r.URL.Path == "/containers/create":
			var body map[string]any
			if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 65536)).Decode(&body); err != nil {
				problems = append(problems, err.Error())
				http.Error(w, "invalid body", 400)
				return
			}
			host, ok := body["HostConfig"].(map[string]any)
			if !ok {
				problems = append(problems, "missing HostConfig")
				http.Error(w, "missing host", 400)
				return
			}
			expected := map[string]any{
				"Cmd": []any{"/usr/bin/codex", "a task with spaces"},
				"Env": []any{"BEE_GATEWAY_HOOK_TOKEN=fixture-hook", "BEE_GATEWAY_TOKEN=fixture-mcp", "HOME=/home/bee", "TMPDIR=/tmp"}, "Tty": true,
				"WorkingDir": "/workspace/src", "User": "1000:1000",
			}
			for key, want := range expected {
				if !reflect.DeepEqual(body[key], want) {
					problems = append(problems, "incorrect "+key)
				}
			}
			if !reflect.DeepEqual(host["Binds"], []any{"/private/session/home:/home/bee:rw", "/projects/demo:/workspace:ro", "/projects/output:/output:rw"}) {
				problems = append(problems, "incorrect mounts")
			}
			if !reflect.DeepEqual(host["SecurityOpt"], []any{"no-new-privileges:true", "apparmor=docker-default"}) {
				problems = append(problems, "incorrect security projection")
			}
			if host["Privileged"] != false || host["ReadonlyRootfs"] != true || host["AutoRemove"] != false {
				problems = append(problems, "incorrect lifecycle/isolation flags")
			}
			w.WriteHeader(201)
			_ = json.NewEncoder(w).Encode(map[string]string{"Id": strings.Repeat("c", 64)})
		case r.Method == "GET" && r.URL.Path == "/containers/"+strings.Repeat("c", 64)+"/json":
			_ = json.NewEncoder(w).Encode(map[string]any{"Id": strings.Repeat("c", 64), "Image": "sha256:" + strings.Repeat("a", 64), "State": map[string]string{"Status": "created"}})
		default:
			problems = append(problems, "unexpected daemon operation "+r.Method+" "+r.URL.Path)
			http.Error(w, "unexpected operation", 400)
		}
	})}
	serving := make(chan struct{})
	go func() { defer close(serving); _ = server.Serve(listener) }()
	defer func() { _ = server.Close(); <-serving }()
	socketJSON, _ := json.Marshal(socket)
	manifest := strings.ReplaceAll(`version: '1.0'
namespace: app
entries:
- name: terminal
  kind: terminal.host
  hide_logs: true
  lifecycle: {auto_start: true}
- name: bounds
  kind: library.lua
  source: file://bounds.lua
- name: configuration
  kind: library.lua
  source: file://configuration.lua
  imports: {bounds: 'app:bounds'}
- name: client
  kind: library.lua
  source: file://client.lua
  modules: [http_client, json]
- name: check
  kind: process.lua
  source: file://check.lua
  method: main
  imports: {configuration: 'app:configuration', client: 'app:client'}
  meta:
    command:
      name: check
      security:
        actor: {id: fixture}
        policies: [app:socket, app:requests]
- name: socket
  kind: security.policy
  policy: {actions: [http_client.unix_socket], resources: [SOCKET], effect: allow}
- name: requests
  kind: security.policy
  policy: {actions: [http_client.request], resources: ['http://docker/*'], effect: allow}
`, "SOCKET", string(socketJSON))
	script := strings.ReplaceAll(`local configuration = require("configuration")
local client = require("client")
local function main()
    local image = "sha256:" .. string.rep("a",64)
    local config, err = configuration.build({image=image,user="1000:1000",network="bee-agents",apparmor="docker-default",
        memory=536870912,nano_cpus=1000000000,pids_limit=128,command={"/usr/bin/codex","a task with spaces"},
        home_source="/private/session/home",home_target="/home/bee",
        environment={HOME="/home/bee",BEE_GATEWAY_TOKEN="fixture-mcp",BEE_GATEWAY_HOOK_TOKEN="fixture-hook"},mounts={
            {source="/projects/demo",target="/workspace",access="read"},
            {source="/projects/output",target="/output",access="write"}},
        working_directory="/workspace/src",labels={
            ["bee.actor_ref"]="actor",["bee.revision_digest"]=string.rep("b",64),["bee.attempt_id"]="attempt",
            ["bee.request_digest"]=string.rep("c",64),["bee.lease_fence"]="1",["bee.image_digest"]=image}})
    if not config then error(tostring(err)) end
    local docker, connect_error = client.new(SOCKET)
    if not docker then error(tostring(connect_error)) end
    local result, create_error = docker:create_container(config, {name="bee-"..string.rep("d",64)})
    if not result or create_error or result.Id ~= string.rep("c",64) then error(tostring(create_error or "not created")) end
    local observed, inspect_error, status = docker:inspect_container(result.Id)
    if not observed or inspect_error or status ~= 200 or observed.Image ~= image or observed.State.Status ~= "created" then
        error(tostring(inspect_error or "inspection differs"))
    end
    return true
end
return {main=main}
`, "SOCKET", string(socketJSON))
	for path, content := range map[string]string{"src/_index.yaml": manifest, "src/check.lua": script, "wippy.lock": "directories:\n  src: src\n  modules: .wippy\n"} {
		if err := os.WriteFile(filepath.Join(root, path), []byte(content), 0600); err != nil {
			return err
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, *runtime, "run", "check")
	command.Dir = root
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("Docker projection host: %w\n%s", err, output)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(problems) > 0 {
		return fmt.Errorf("daemon assertions: %s", strings.Join(problems, "; "))
	}
	creates, inspects := 0, 0
	for _, call := range calls {
		if call == "POST /containers/create" {
			creates++
		}
		if call == "GET /containers/"+strings.Repeat("c", 64)+"/json" {
			inspects++
		}
	}
	if creates != 1 || inspects != 1 {
		return fmt.Errorf("expected one create and inspection, got %v", calls)
	}
	fmt.Println("PASS: Bee configuration through direct Docker client create/inspect and actual Lua HTTP; no start or container execution")
	return nil
}
