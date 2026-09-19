// SPDX-License-Identifier: MIT
// Runs the production configuration projection against a local Docker daemon.
// Uses an already-present image, disposable mounts, and no network or credentials.
package main

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func run() error {
	runtime := flag.String("runtime", "", "selected Bee runtime")
	image := flag.String("image", "", "already-local immutable image containing /bin/sh, grep and touch")
	socket := flag.String("socket", "/var/run/docker.sock", "local Docker Unix socket")
	flag.Parse()
	if *runtime == "" || !strings.HasPrefix(*image, "sha256:") || len(*image) != 71 || os.Getuid() == 0 || os.Getgid() == 0 {
		return fmt.Errorf("runtime, immutable image and non-root fixture user required")
	}
	root, err := os.MkdirTemp("", "bee-docker-sandbox-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	for _, dir := range []string{"src", "home", "project"} {
		if err := os.Mkdir(filepath.Join(root, dir), 0700); err != nil {
			return err
		}
	}
	for target, source := range map[string]string{"configuration.lua": "src/placement/docker/configuration.lua", "bounds.lua": "src/threads/records/bounds.lua"} {
		data, err := os.ReadFile(source)
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(root, "src", target), data, 0600); err != nil {
			return err
		}
	}
	labels := map[string]string{"bee.actor_ref": "sandbox-fixture", "bee.revision_digest": strings.Repeat("b", 64), "bee.attempt_id": filepath.Base(root), "bee.request_digest": strings.Repeat("c", 64), "bee.lease_fence": "1", "bee.image_digest": *image}
	command := `set -eu
 grep -q '^NoNewPrivs:[[:space:]]*1$' /proc/self/status
 grep -q '^Seccomp:[[:space:]]*2$' /proc/self/status
 grep -q '^CapEff:[[:space:]]*0000000000000000$' /proc/self/status
 if touch /bee-root-write 2>/dev/null; then exit 31; fi
 if touch /workspace/project-write 2>/dev/null; then exit 32; fi
 touch "$HOME/home-write"
 printf '#!/bin/sh\nexit 0\n' >/tmp/noexec-probe
 chmod +x /tmp/noexec-probe
 if /tmp/noexec-probe 2>/dev/null; then exit 33; fi
 printf 'BEE_SANDBOX_OK\n'
 `
	spec, err := json.Marshal(map[string]any{"image": *image, "user": fmt.Sprintf("%d:%d", os.Getuid(), os.Getgid()), "network": "none", "memory": 134217728, "nano_cpus": 1000000000, "pids_limit": 32, "command": []string{"/bin/sh", "-c", command}, "home_source": filepath.Join(root, "home"), "home_target": "/home/bee", "mounts": []map[string]string{{"source": filepath.Join(root, "project"), "target": "/workspace", "access": "read"}}, "working_directory": "/workspace", "labels": labels})
	if err != nil {
		return err
	}
	literal, _ := json.Marshal(string(spec))
	script := `local fs = require("fs")
local json = require("json")
local configuration = require("configuration")
local function main()
 local specification, decode_error = json.decode(` + string(literal) + `)
 if not specification then error(tostring(decode_error)) end
 local config, err = configuration.build(specification)
 if not config then error(tostring(err)) end
 local encoded, encode_error = json.encode(config)
 if not encoded then error(tostring(encode_error)) end
 local output, open_error = fs.get("app:output")
 if not output then error(tostring(open_error)) end
 local written, write_error = output:writefile("/config.json", encoded, {atomic = true})
 if not written then error(tostring(write_error)) end
 return true
end
return {main=main}
`
	manifest := `version: '1.0'
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
- name: check
  kind: process.lua
  source: file://check.lua
  method: main
  modules: [json, fs]
  imports: {configuration: 'app:configuration'}
  meta: {command: {name: check, security: {actor: {id: fixture}, policies: [app:write]}}}
- name: output
  kind: fs.directory
  directory: .
- name: write
  kind: security.policy
  policy: {actions: [fs.get, fs.write], resources: [app:output], effect: allow}
`
	for path, content := range map[string]string{"src/_index.yaml": manifest, "src/check.lua": script, "wippy.lock": "directories:\n  src: src\n  modules: .wippy\n"} {
		if err := os.WriteFile(filepath.Join(root, path), []byte(content), 0600); err != nil {
			return err
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, *runtime, "run", "check")
	cmd.Dir = root
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("configuration projection: %w\n%s", err, output)
	}
	configBytes, err := os.ReadFile(filepath.Join(root, "config.json"))
	if err != nil {
		return fmt.Errorf("read projected config: %w", err)
	}
	config := string(configBytes)
	if !json.Valid(configBytes) {
		return fmt.Errorf("projection returned invalid JSON")
	}
	transport := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", *socket)
	}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 35 * time.Second}
	call := func(method, path string, body []byte) ([]byte, error) {
		request, err := http.NewRequestWithContext(ctx, method, "http://docker"+path, bytes.NewReader(body))
		if err != nil {
			return nil, err
		}
		request.Header.Set("Content-Type", "application/json")
		response, err := client.Do(request)
		if err != nil {
			return nil, err
		}
		defer response.Body.Close()
		data, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
		if err != nil {
			return nil, err
		}
		if response.StatusCode < 200 || response.StatusCode >= 300 {
			return nil, fmt.Errorf("%s %s: HTTP %d: %s", method, path, response.StatusCode, data)
		}
		return data, nil
	}
	// Refuse an absent image; this test never pulls one.
	if _, err := call("GET", "/images/"+*image+"/json", nil); err != nil {
		return err
	}
	created, err := call("POST", "/containers/create?name="+filepath.Base(root), []byte(config))
	if err != nil {
		return err
	}
	var identity struct {
		ID string `json:"Id"`
	}
	if err := json.Unmarshal(created, &identity); err != nil || len(identity.ID) != 64 {
		return fmt.Errorf("invalid created container identity")
	}
	if _, err := hex.DecodeString(identity.ID); err != nil {
		return fmt.Errorf("invalid container ID: %w", err)
	}
	// Cleanup has an independent deadline even if the execution budget expires.
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		request, _ := http.NewRequestWithContext(cleanup, "DELETE", "http://docker/containers/"+identity.ID+"?force=1", nil)
		response, err := client.Do(request)
		if err == nil {
			response.Body.Close()
		}
	}()
	if _, err := call("POST", "/containers/"+identity.ID+"/start", nil); err != nil {
		return err
	}
	waited, err := call("POST", "/containers/"+identity.ID+"/wait?condition=not-running", nil)
	if err != nil {
		return err
	}
	var completion struct{ StatusCode int }
	if err := json.Unmarshal(waited, &completion); err != nil {
		return err
	}
	logs, err := call("GET", "/containers/"+identity.ID+"/logs?stdout=1&stderr=1", nil)
	if err != nil {
		return err
	}
	if completion.StatusCode != 0 || !strings.Contains(string(logs), "BEE_SANDBOX_OK") {
		return fmt.Errorf("sandbox probe exited %d: %s", completion.StatusCode, logs)
	}
	if _, err := os.Stat(filepath.Join(root, "home", "home-write")); err != nil {
		return fmt.Errorf("private home was not writable: %w", err)
	}
	inspected, err := call("GET", "/containers/"+identity.ID+"/json", nil)
	if err != nil {
		return err
	}
	var observed struct {
		HostConfig struct {
			ReadonlyRootfs bool
			NetworkMode    string
			Memory         int64
			PidsLimit      int64
		}
	}
	if err := json.Unmarshal(inspected, &observed); err != nil {
		return err
	}
	if !observed.HostConfig.ReadonlyRootfs || observed.HostConfig.NetworkMode != "none" || observed.HostConfig.Memory != 134217728 || observed.HostConfig.PidsLimit != 32 {
		return fmt.Errorf("daemon did not preserve isolation configuration")
	}
	if _, err := call("DELETE", "/containers/"+identity.ID, nil); err != nil {
		return err
	}
	absenceRequest, err := http.NewRequestWithContext(ctx, "GET", "http://docker/containers/"+identity.ID+"/json", nil)
	if err != nil {
		return err
	}
	absence, err := client.Do(absenceRequest)
	if err != nil {
		return err
	}
	absence.Body.Close()
	if absence.StatusCode != http.StatusNotFound {
		return fmt.Errorf("container cleanup not confirmed: HTTP %d", absence.StatusCode)
	}
	fmt.Println("PASS: production Docker config runs offline with seccomp, no-new-privileges, no capabilities, read-only project/root and noexec tmp; private home writable")
	return nil
}
