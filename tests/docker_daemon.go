// SPDX-License-Identifier: MIT
// Focused dependency-slice protocol proof for the optional Docker daemon
// adapter. The fixture composes the reviewed local userspace/docker-client
// package, the adapter package and the narrow Bee helper slice it imports,
// plus a private Unix HTTP daemon. It never needs Docker credentials or a real
// daemon and does not claim standalone package publication.
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
	"sync"
	"time"
)

const containerID = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
const transportID = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
const imageID = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	runtime := flag.String("runtime", "", "selected Bee runtime executable")
	dockerSource := flag.String("docker-source", "", "reviewed userspace/docker-client package directory")
	flag.Parse()
	if *runtime == "" || *dockerSource == "" {
		return fmt.Errorf("runtime and docker-source are required")
	}
	root, err := os.MkdirTemp("", "bee-docker-daemon-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	source := filepath.Join(root, "src")
	if err := os.Mkdir(source, 0700); err != nil {
		return err
	}
	componentSource := filepath.Join("modules", "bee-placement-docker-daemon", "src")
	userspaceIndex, readIndexErr := os.ReadFile(filepath.Join(*dockerSource, "_index.yaml"))
	if readIndexErr != nil {
		return fmt.Errorf("read userspace component manifest %s: %w", filepath.Join(*dockerSource, "_index.yaml"), readIndexErr)
	}
	userspaceReadme, readReadmeErr := os.ReadFile(filepath.Join(*dockerSource, "README.md"))
	if readReadmeErr != nil {
		return fmt.Errorf("read userspace component README %s: %w", filepath.Join(*dockerSource, "README.md"), readReadmeErr)
	}
	files := map[string]string{
		"bee/placement/docker/_index.yaml":              filepath.Join(componentSource, "_index.yaml"),
		"bee/placement/docker/daemon.lua":               filepath.Join(componentSource, "daemon.lua"),
		"bee/placement/docker-helper/_index.yaml":       filepath.Join("src", "placement", "docker", "_index.yaml"),
		"bee/placement/docker-helper/configuration.lua": filepath.Join("src", "placement", "docker", "configuration.lua"),
		"bee/placement/docker-helper/inspection.lua":    filepath.Join("src", "placement", "docker", "inspection.lua"),
		"bee/placement/docker-helper/README.md":         filepath.Join("src", "placement", "docker", "README.md"),
		"bee/threads/records/bounds.lua":                filepath.Join("src", "threads", "records", "bounds.lua"),
		"userspace/docker/client.lua":                   filepath.Join(*dockerSource, "client.lua"),
	}
	for target, origin := range files {
		data, readErr := os.ReadFile(origin)
		if readErr != nil {
			return fmt.Errorf("read %s: %w", origin, readErr)
		}
		targetPath := filepath.Join(source, target)
		if mkdirErr := os.MkdirAll(filepath.Dir(targetPath), 0700); mkdirErr != nil {
			return mkdirErr
		}
		if writeErr := os.WriteFile(targetPath, data, 0600); writeErr != nil {
			return writeErr
		}
	}
	socket := filepath.Join(root, "daemon.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		return err
	}
	defer listener.Close()
	var mu sync.Mutex
	status := "created"
	startedAt := "0001-01-01T00:00:00Z"
	removed := false
	startCalls := 0
	containerName := ""
	inspectName := ""
	labels := map[string]string{
		"bee.attempt_id":     "attempt-daemon",
		"bee.request_digest": strings.Repeat("b", 64),
	}
	server := &http.Server{ReadHeaderTimeout: 5 * time.Second, Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == "/_ping" {
			_, _ = w.Write([]byte(`{}`))
			return
		}
		if r.URL.Path == "/containers/create" && r.Method == http.MethodPost {
			status = "created"
			removed = false
			containerName = r.URL.Query().Get("name")
			inspectName = containerName
			w.WriteHeader(http.StatusCreated)
			_ = json.NewEncoder(w).Encode(map[string]string{"Id": containerID})
			return
		}
		if r.URL.Path == "/containers/json" && r.Method == http.MethodGet {
			filters := r.URL.Query().Get("filters")
			multipleName := "bee-" + strings.Repeat("e", 64)
			zeroName := "bee-" + strings.Repeat("f", 64)
			switch {
			case strings.Contains(filters, multipleName):
				inspectName = multipleName
				_ = json.NewEncoder(w).Encode([]map[string]any{{"Id": containerID, "Names": []string{"/" + multipleName}}, {"Id": containerID, "Names": []string{"/" + multipleName}}})
			case strings.Contains(filters, zeroName):
				_ = json.NewEncoder(w).Encode([]map[string]any{})
			default:
				inspectName = containerName
				_ = json.NewEncoder(w).Encode([]map[string]any{{"Id": containerID, "Names": []string{"/" + containerName}}})
			}
			return
		}
		if r.URL.Path == "/containers/"+containerID+"/json" && r.Method == http.MethodGet {
			if removed {
				w.WriteHeader(http.StatusNotFound)
				_ = json.NewEncoder(w).Encode(map[string]string{"message": "No such container"})
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"Id": containerID, "Name": "/" + inspectName, "Image": imageID, "AppArmorProfile": "docker-default",
				"Config": map[string]any{"Labels": labels},
				"State":  map[string]any{"Status": status, "StartedAt": startedAt, "ExitCode": 0},
			})
			return
		}
		if r.URL.Path == "/containers/"+containerID+"/start" && r.Method == http.MethodPost {
			startCalls++
			status = "running"
			startedAt = "2026-09-13T15:40:00.123456789Z"
			_, _ = w.Write([]byte(`{}`))
			return
		}
		if r.URL.Path == "/containers/"+containerID+"/stop" && r.Method == http.MethodPost {
			status = "exited"
			_, _ = w.Write([]byte(`{}`))
			return
		}
		if r.URL.Path == "/containers/"+containerID && r.Method == http.MethodDelete {
			removed = true
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if r.URL.Path == "/containers/"+transportID+"/json" && r.Method == http.MethodGet {
			hijacker, ok := w.(http.Hijacker)
			if !ok {
				http.Error(w, "hijacking unavailable", http.StatusInternalServerError)
				return
			}
			connection, _, hijackErr := hijacker.Hijack()
			if hijackErr == nil {
				_ = connection.Close()
			}
			return
		}
		http.Error(w, "unexpected daemon request", http.StatusBadRequest)
	})}
	go func() { _ = server.Serve(listener) }()
	defer server.Close()
	socketJSON, _ := json.Marshal(socket)
	// Only bounds is imported by the adapter; this is an explicit dependency
	// slice rather than a standalone bee/threads package acceptance.
	recordsSliceIndex := `version: '1.0'
namespace: bee.threads.records
entries:
- name: bounds
  kind: library.lua
  source: file://bounds.lua
`
	hostIndex := fmt.Sprintf(`version: '1.0'
namespace: bee.placement.docker.daemon
entries:
- name: daemon_ref
  kind: registry.entry
  meta: {type: bee.resource_ref}
  data: {resource_ref: bee.placement.docker.daemon:daemon_binding}
- name: daemon_binding
  kind: registry.entry
  meta: {type: bee.docker_daemon}
  data: {socket_path: %s}
`, socketJSON)
	manifest := fmt.Sprintf(`version: '1.0'
namespace: app
entries:
- name: terminal
  kind: terminal.host
  hide_logs: true
  lifecycle: {auto_start: true}
- name: socket
  kind: security.policy
  policy: {actions: [http_client.unix_socket], resources: [%s], effect: allow}
- name: requests
  kind: security.policy
  policy: {actions: [http_client.request], resources: ['http://docker/*'], effect: allow}
- name: registry
  kind: security.policy
  policy: {actions: [registry.get], resources: '*', effect: allow}
- name: check
  kind: process.lua
  source: file://check.lua
  method: main
  imports: {daemon: bee.placement.docker.daemon:daemon}
  meta:
    command:
      name: check
      security: {actor: {id: fixture}, policies: [app:socket, app:requests, app:registry]}
`, socketJSON)
	check := fmt.Sprintf(`local daemon = require("daemon")
local function main()
local labels = { ["bee.attempt_id"] = "attempt-daemon", ["bee.request_digest"] = string.rep("b", 64) }
local image = %q
local id = %q
local create_name = "bee-"..string.rep("d", 64)
local expected = {container_id=id, image_id=image, apparmor="docker-default", labels=labels}
local config = {Image=image, User="1000:1000", Labels=labels, HostConfig={SecurityOpt={"apparmor=docker-default"}}}
local created, create_error = daemon.create({name=create_name, config=config, expected={image_id=image, apparmor="docker-default", labels=labels}})
if not created or create_error or created.state ~= "created" then error((create_error and create_error.message) or "create did not confirm created state") end
local recovered, recovery_error = daemon.recover_create({name=create_name, expected={image_id=image, apparmor="docker-default", labels=labels}})
if not recovered or recovery_error or recovered.container_id ~= id or recovered.state ~= "created" then error((recovery_error and recovery_error.message) or "lost create reply was not recovered") end
local multiple, multiple_error = daemon.recover_create({name="bee-"..string.rep("e", 64), expected={image_id=image, apparmor="docker-default", labels=labels}})
if multiple ~= nil or not multiple_error or multiple_error.kind ~= "unavailable" then error("multiple create recovery matches were accepted") end
local running, start_error = daemon.start({container_id=id, expected=expected})
if not running or start_error or running.state ~= "running" or not running.started_at then error((start_error and start_error.message) or "start did not confirm running state") end
expected.started_at = running.started_at
local inspected, inspect_error = daemon.inspect({container_id=id, expected=expected})
if not inspected or inspect_error or inspected.started_at ~= running.started_at then error((inspect_error and inspect_error.message) or "inspect did not preserve StartedAt") end
local mismatched, mismatch_error = daemon.stop({container_id=id, expected={container_id=id, image_id="sha256:"..string.rep("c", 64), apparmor="docker-default", labels=labels}, timeout_seconds=1})
if mismatched ~= nil or not mismatch_error or mismatch_error.kind ~= "mismatch" then error("identity mismatch was not refused before stop") end
local exited, stop_error = daemon.stop({container_id=id, expected=expected, timeout_seconds=1})
if not exited or stop_error or exited.state ~= "exited" or exited.exit_code ~= 0 then error((stop_error and stop_error.message) or "stop did not confirm exit") end
local deleted, remove_error = daemon.remove({container_id=id, expected=expected})
if deleted ~= true or remove_error then error((remove_error and remove_error.message) or "remove did not confirm absence") end
local absent, absent_error = daemon.inspect({container_id=id, expected=expected})
if absent ~= nil or not absent_error or absent_error.kind ~= "absent" or absent_error.status ~= 404 then error("confirmed Docker absence was not preserved") end
local zero, zero_error = daemon.recover_create({name="bee-"..string.rep("f", 64), expected={image_id=image, apparmor="docker-default", labels=labels}})
if zero ~= nil or not zero_error or zero_error.kind ~= "unavailable" then error("zero create recovery matches were accepted") end
local transport, transport_error = daemon.inspect({container_id="dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", expected={container_id="dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", image_id=image, apparmor="docker-default", labels=labels}})
if transport ~= nil or not transport_error or transport_error.kind ~= "unavailable" or transport_error.status ~= nil then error("transport failure was treated as a lifecycle fact") end
return true
end
return {main=main}
`, imageID, containerID)
	for path, content := range map[string]string{
		"wippy.lock":      "directories:\n  src: src\n  modules: .wippy\n",
		"src/_index.yaml": manifest,
		"src/bee/placement/docker-host/_index.yaml": hostIndex,
		"src/bee/threads/records/_index.yaml":       recordsSliceIndex,
		"src/check.lua":                             check,
	} {
		if mkdirErr := os.MkdirAll(filepath.Dir(filepath.Join(root, path)), 0700); mkdirErr != nil {
			return mkdirErr
		}
		if writeErr := os.WriteFile(filepath.Join(root, path), []byte(content), 0600); writeErr != nil {
			return writeErr
		}
	}
	if mkdirErr := os.MkdirAll(filepath.Join(root, "src/userspace/docker"), 0700); mkdirErr != nil {
		return mkdirErr
	}
	if writeErr := os.WriteFile(filepath.Join(root, "src/userspace/docker/_index.yaml"), userspaceIndex, 0600); writeErr != nil {
		return writeErr
	}
	if writeErr := os.WriteFile(filepath.Join(root, "src/userspace/docker/README.md"), userspaceReadme, 0600); writeErr != nil {
		return writeErr
	}
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	for _, args := range [][]string{{"lint", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true"}, {"run", "check"}} {
		command := exec.CommandContext(ctx, *runtime, args...)
		command.Dir = root
		output, commandErr := command.CombinedOutput()
		if commandErr != nil {
			return fmt.Errorf("daemon adapter %s: %w\n%s", args[0], commandErr, output)
		}
	}
	mu.Lock()
	defer mu.Unlock()
	if startCalls != 1 {
		return fmt.Errorf("identity mismatch caused %d Docker start calls; want one", startCalls)
	}
	fmt.Println("PASS: optional Docker daemon adapter validates identity, lost-create recovery, lifecycle and confirmed absence over a host-bound Unix client")
	return nil
}
