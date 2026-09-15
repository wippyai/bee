// SPDX-License-Identifier: MIT
// Source-free acceptance of the runtime's registered exec.docker PTY path.
// The fixture uses only runtime exec and terminal APIs; it does not load Bee's
// Docker placement or a userspace Docker client.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/creack/pty"
)

const defaultDockerImage = "sha256:aa09691f441f07a6d1f076f25470751bff882a4ba88274f3d7f9fa5af542f0ce"

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func dockerRequest(socket, method, path string) ([]byte, int, error) {
	transport := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", socket)
	}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 10 * time.Second}
	req, err := http.NewRequest(method, "http://docker"+path, nil)
	if err != nil {
		return nil, 0, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	return body, resp.StatusCode, err
}

func containers(socket, image, evidenceSource string) (map[string]bool, error) {
	body, status, err := dockerRequest(socket, http.MethodGet, "/containers/json?all=true")
	if err != nil {
		return nil, err
	}
	if status != http.StatusOK {
		return nil, fmt.Errorf("Docker list HTTP %d", status)
	}
	var rows []struct {
		ID     string `json:"Id"`
		Image  string `json:"Image"`
		Mounts []struct {
			Source      string `json:"Source"`
			Destination string `json:"Destination"`
		} `json:"Mounts"`
	}
	if err := json.Unmarshal(body, &rows); err != nil {
		return nil, err
	}
	result := map[string]bool{}
	for _, row := range rows {
		if row.Image != image {
			continue
		}
		for _, mount := range row.Mounts {
			if mount.Source == evidenceSource && mount.Destination == "/evidence" {
				result[row.ID] = true
				break
			}
		}
	}
	return result, nil
}

func inspect(socket, id string) (map[string]any, error) {
	body, status, err := dockerRequest(socket, http.MethodGet, "/containers/"+id+"/json")
	if err != nil {
		return nil, err
	}
	if status != http.StatusOK {
		return nil, fmt.Errorf("Docker inspect HTTP %d", status)
	}
	var result map[string]any
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, err
	}
	return result, nil
}

func envFor(root string) []string {
	return []string{
		"HOME=" + filepath.Join(root, "home"),
		"XDG_CONFIG_HOME=" + filepath.Join(root, "config"),
		"XDG_DATA_HOME=" + filepath.Join(root, "data"),
		"XDG_STATE_HOME=" + filepath.Join(root, "state"),
	}
}

func waitForFile(path, text string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		body, err := os.ReadFile(path)
		if err == nil && strings.Contains(string(body), text) {
			return nil
		}
		time.Sleep(25 * time.Millisecond)
	}
	body, _ := os.ReadFile(path)
	return fmt.Errorf("timed out waiting for %q in %s: %s", text, path, body)
}

type ptyRun struct {
	terminal *os.File
	cmd      *exec.Cmd
	mu       sync.Mutex
	output   []byte
	done     chan struct{}
}

func startRuntime(runtime, root string, env []string) (*ptyRun, error) {
	cmd := exec.Command(runtime, "run", "--host", "app:terminal", "check")
	cmd.Dir = root
	cmd.Env = append(append(os.Environ(), env...), "TERM=xterm-256color")
	term, err := pty.StartWithSize(cmd, &pty.Winsize{Cols: 40, Rows: 12})
	if err != nil {
		return nil, err
	}
	run := &ptyRun{terminal: term, cmd: cmd, done: make(chan struct{})}
	go func() {
		buf := make([]byte, 32768)
		for {
			n, readErr := term.Read(buf)
			if n > 0 {
				run.mu.Lock()
				run.output = append(run.output, buf[:n]...)
				run.mu.Unlock()
			}
			if readErr != nil {
				close(run.done)
				return
			}
		}
	}()
	return run, nil
}

func (r *ptyRun) close() {
	_ = r.terminal.Close()
	if r.cmd.Process != nil {
		_ = r.cmd.Process.Kill()
	}
}

func run() error {
	runtime := flag.String("runtime", "", "runtime executable with exec.docker and terminal APIs")
	image := flag.String("image", defaultDockerImage, "immutable local Docker image")
	socket := flag.String("socket", "/var/run/docker.sock", "Docker Unix socket")
	root := flag.String("root", ".", "Bee repository root")
	flag.Parse()
	if *runtime == "" || *root == "" || len(*image) != 71 || !strings.HasPrefix(*image, "sha256:") || strings.Trim((*image)[7:], "0123456789abcdef") != "" {
		return errors.New("runtime, repository root and a 64 digit immutable image are required")
	}
	if os.Getuid() == 0 || os.Getgid() == 0 {
		return errors.New("non-root user required")
	}
	if _, err := os.Stat(*runtime); err != nil {
		return err
	}
	fixture, err := os.MkdirTemp("", ".bee-exec-docker-pty-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(fixture)
	var fresh string
	for _, name := range []string{"src", "home", "config", "data", "state", "evidence"} {
		if err := os.MkdirAll(filepath.Join(fixture, name), 0700); err != nil {
			return err
		}
	}
	evidenceSource := filepath.Join(fixture, "evidence")
	command := "/bin/sh -c 'printf READY\\n > /evidence/output; stty size >> /evidence/output; while IFS= read -r line; do if [ \"$line\" = size ]; then stty size >> /evidence/output; else printf ECHO:%s\\n \"$line\" >> /evidence/output; fi; done'"
	index := fmt.Sprintf(`version: '1.0'
namespace: app
entries:
- name: terminal
  kind: terminal.host
  hide_logs: true
  lifecycle: {auto_start: true}
- name: docker
  kind: exec.docker
  image: %s
  host: unix://%s
  user: '%d:%d'
  network_mode: none
  auto_remove: true
  volumes: [%q]
- name: run_policy
  kind: security.policy
  policy:
    actions: [exec.get, exec.run, process.spawn, process.spawn.monitored, process.host, process.monitor, process.context, tty.mount, tty.observe, tty.input, tty.resize]
    resources: ['app:docker', %q, app:terminal, app:child, context]
    effect: allow
- name: child
  kind: process.lua
  source: file://child.lua
  method: main
  modules: [exec, process, time, channel]
- name: check
  kind: process.lua
  source: file://check.lua
  method: main
  modules: [process, channel, time, tty, exec]
  meta:
    command:
      name: check
      security:
        actor: {id: fixture}
        policies: [app:run_policy]
`, *image, *socket, os.Getuid(), os.Getgid(), filepath.Join(fixture, "evidence")+":/evidence:rw", command)
	if err := os.WriteFile(filepath.Join(fixture, "src", "_index.yaml"), []byte(index), 0600); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(fixture, "wippy.lock"), []byte("version: '1.0'\ndirectories:\n  src: src\n  modules: .wippy\n"), 0600); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(fixture, ".wippy.yaml"), []byte("version: '1.0'\n"), 0600); err != nil {
		return err
	}
	childLua := fmt.Sprintf(`local exec = require("exec")
local time = require("time")
local function main()
    local executor, executor_error = exec.get("app:docker")
    if not executor then error(tostring(executor_error)) end
    local child, child_error = executor:exec(%q, {pty = {width = 40, height = 12, term = "xterm-256color"}})
    if not child then error(tostring(child_error)) end
    local terminal, terminal_error = child:attach_terminal()
    if not terminal then error(tostring(terminal_error)) end
    assert(terminal:send({type = "paste", text = "hello\n"}))
    assert(terminal:send({type = "resize", width = 120, height = 20}))
    assert(terminal:send({type = "paste", text = "size\n"}))
    time.after("4s"):receive()
    local closed, close_error = terminal:close()
    if not closed then error(tostring(close_error)) end
    terminal:done():receive()
    return true
end
return {main = main}
`, command)

	checkLua := `local process = require("process")
local channel = require("channel")
local time = require("time")
local tty = require("tty")
local function main()
    assert(tty.events())
    assert(tty.start())
    local view, view_error = tty.viewport({width = 40, height = 12})
    if not view then error(tostring(view_error)) end
    local grant, grant_error = view:grant()
    if not grant then error(tostring(grant_error)) end
    local parent = process.pid()
    local child, child_error = process.with_options({terminal = grant}):spawn_monitored("app:child", "app:terminal", parent, parent)
    if not child then error(tostring(child_error)) end
    time.after("8s"):receive()
    return true
end
return {main = main}
`
	if err := os.WriteFile(filepath.Join(fixture, "src", "child.lua"), []byte(childLua), 0600); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(fixture, "src", "check.lua"), []byte(checkLua), 0600); err != nil {
		return err
	}
	env := envFor(fixture)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	lint := exec.CommandContext(ctx, *runtime, "lint", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true")
	lint.Dir, lint.Env = fixture, append(os.Environ(), env...)
	if output, err := lint.CombinedOutput(); err != nil {
		return fmt.Errorf("lint: %w\n%s", err, output)
	}
	run, err := startRuntime(*runtime, fixture, env)
	if err != nil {
		return err
	}
	defer run.close()
	if err := waitForFile(filepath.Join(fixture, "evidence", "output"), "READY", 15*time.Second); err != nil {
		return err
	}
	if err := waitForFile(filepath.Join(fixture, "evidence", "output"), "ECHO:hello", 5*time.Second); err != nil {
		return err
	}
	if err := waitForFile(filepath.Join(fixture, "evidence", "output"), "20 120", 5*time.Second); err != nil {
		return err
	}
	// The process owns a short close deadline. Inspect while it is still alive
	// to prove this is an actual TTY-backed container created by exec.docker.
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		current, listErr := containers(*socket, *image, evidenceSource)
		if listErr == nil {
			for id := range current {
				if fresh != "" && fresh != id {
					return errors.New("exec.docker created multiple containers for one evidence mount")
				}
				fresh = id
			}
		}
		if fresh != "" {
			break
		}
		time.Sleep(25 * time.Millisecond)
	}
	if fresh == "" {
		return errors.New("exec.docker created no observable container")
	}
	obj, err := inspect(*socket, fresh)
	if err != nil {
		return err
	}
	config, ok := obj["Config"].(map[string]any)
	if !ok || config["Tty"] != true {
		return fmt.Errorf("exec.docker container was not allocated a TTY: %#v", config)
	}
	cmd, ok := config["Cmd"].([]any)
	if !ok || len(cmd) == 0 || cmd[0] != "/bin/sh" {
		return fmt.Errorf("unexpected Docker command: %#v", config["Cmd"])
	}
	select {
	case err := <-waitCommand(run.cmd):
		if err != nil {
			return fmt.Errorf("runtime run: %w", err)
		}
	case <-time.After(10 * time.Second):
		return errors.New("runtime run did not finish after terminal close")
	}
	deadline = time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		current, listErr := containers(*socket, *image, evidenceSource)
		if listErr == nil {
			if len(current) == 0 {
				fmt.Println("PASS: registered exec.docker created a real PTY, delivered input/output, resized, closed and removed its container")
				return nil
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	return errors.New("exec.docker container remained after terminal close")
}

func waitCommand(cmd *exec.Cmd) <-chan error {
	ch := make(chan error, 1)
	go func() { ch <- cmd.Wait() }()
	return ch
}
