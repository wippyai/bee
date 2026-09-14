// SPDX-License-Identifier: MIT
// Acceptance of production Codex session flag and hook configuration against
// the installed Codex app-server. The provider points at a local rejecting
// fixture, so no real model or account service is contacted.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

const (
	defaultRuntime = ".wippy/bin/bee-wippy"
	defaultCodex   = "codex"
	hookToken      = "fixture-hook-token"
	toolToken      = "fixture-tool-token"
)

type hookObservation struct {
	method     string
	authorized bool
	params     map[string]any
}

type mcpFixture struct {
	server *httptest.Server
	mu     sync.Mutex
	seen   []hookObservation
}

func newRejectingModelFixture() *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
}

func newMCPFixture() *mcpFixture {
	fixture := &mcpFixture{}
	fixture.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		var request map[string]any
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&request); err != nil {
			http.Error(w, "invalid JSON", http.StatusBadRequest)
			return
		}
		method, _ := request["method"].(string)
		params, _ := request["params"].(map[string]any)
		fixture.mu.Lock()
		fixture.seen = append(fixture.seen, hookObservation{
			method:     method,
			authorized: r.Header.Get("Authorization") == "Bearer "+hookToken,
			params:     params,
		})
		fixture.mu.Unlock()
		if _, hasID := request["id"]; !hasID {
			w.WriteHeader(http.StatusAccepted)
			return
		}
		var result any
		switch method {
		case "initialize":
			result = map[string]any{
				"protocolVersion": "2025-03-26",
				"capabilities":    map[string]any{"tools": map[string]any{}},
				"serverInfo":      map[string]any{"name": "fixture", "version": "1"},
			}
		case "tools/list":
			result = map[string]any{"tools": []any{map[string]any{
				"name":        "hook",
				"description": "Fixture hook receiver",
				"inputSchema": map[string]any{"type": "object", "additionalProperties": true},
			}}}
		case "tools/call":
			result = map[string]any{"content": []any{map[string]any{"type": "text", "text": "{}"}}}
		case "ping":
			result = map[string]any{}
		default:
			result = map[string]any{}
		}
		response := map[string]any{"jsonrpc": "2.0", "id": request["id"], "result": result}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(response)
	}))
	return fixture
}

func (f *mcpFixture) observations() []hookObservation {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]hookObservation(nil), f.seen...)
}

func copyFile(dst, src string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0600)
}

func environment(root string) []string {
	path := os.Getenv("PATH")
	if path == "" {
		path = "/usr/local/bin:/usr/bin:/bin"
	}
	return []string{
		"PATH=" + path,
		"HOME=" + filepath.Join(root, "home"),
		"CODEX_HOME=" + filepath.Join(root, "home"),
		"BEE_HOOK_TOKEN=" + hookToken,
		"BEE_TOOL_TOKEN=" + toolToken,
	}
}

func writeFixture(root string, port int, repo string) error {
	for _, directory := range []string{"src", "home"} {
		if err := os.MkdirAll(filepath.Join(root, directory), 0700); err != nil {
			return err
		}
	}
	for _, item := range []struct{ name, path string }{
		{"configuration.lua", filepath.Join(repo, "src", "driver", "codex", "configuration.lua")},
		{"bounds.lua", filepath.Join(repo, "src", "threads", "records", "bounds.lua")},
		{"canonical.lua", filepath.Join(repo, "src", "threads", "records", "canonical.lua")},
	} {
		if err := copyFile(filepath.Join(root, "src", item.name), item.path); err != nil {
			return err
		}
	}
	if err := os.WriteFile(filepath.Join(root, "wippy.lock"), []byte("directories:\n  src: ./src\n"), 0600); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(root, ".wippy.yaml"), []byte("version: '1.0'\nshutdown:\n  timeout: 2s\n"), 0600); err != nil {
		return err
	}
	index := `version: '1.0'
namespace: app
entries:
- name: terminal
  kind: terminal.host
  hide_logs: true
  lifecycle: {auto_start: true}
- name: output
  kind: fs.directory
  directory: .
- name: write_policy
  kind: security.policy
  policy:
    actions: [fs.get, fs.write]
    resources: "*"
    effect: allow
- name: bounds
  kind: library.lua
  source: file://bounds.lua
- name: canonical
  kind: library.lua
  source: file://canonical.lua
- name: configuration
  kind: library.lua
  source: file://configuration.lua
  modules: [hash]
  imports: {bounds: 'app:bounds', canonical: 'app:canonical'}
- name: emit
  kind: process.lua
  source: file://emit.lua
  method: main
  modules: [json, fs]
  imports: {configuration: 'app:configuration'}
  meta:
    command:
      name: emit
      security:
        actor: {id: fixture}
        policies: [app:write_policy]
`
	if err := os.WriteFile(filepath.Join(root, "src", "_index.yaml"), []byte(index), 0600); err != nil {
		return err
	}
	emit := fmt.Sprintf(`local configuration = require("configuration")
local json = require("json")
local fs = require("fs")
local function main()
 local args, err = configuration.session_arguments({endpoint="127.0.0.1:%d", action_id="fixture", tools={"thread_read"}, hooks={"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"}, token_environment="BEE_TOOL_TOKEN", hook_token_environment="BEE_HOOK_TOKEN"}, nil)
 if not args then error(tostring(err)) end
 local volume, volume_error = fs.get("app:output")
 if not volume then error(tostring(volume_error)) end
 local written, write_error = volume:writefile("args.json", json.encode(args))
 if not written then error(tostring(write_error)) end
 return true
end
return {main=main}
`, port)
	return os.WriteFile(filepath.Join(root, "src", "emit.lua"), []byte(emit), 0600)
}

type codexMessage struct {
	value map[string]any
	err   error
}

type codexProcess struct {
	cmd        *exec.Cmd
	stdin      io.WriteCloser
	lines      chan codexMessage
	stop       chan struct{}
	stopOnce   sync.Once
	readerDone chan struct{}
}

func startCodex(path, root string, env []string, args []string) (*codexProcess, error) {
	cmd := exec.Command(path, args...)
	cmd.Dir = root
	cmd.Env = env
	cmd.Stderr = io.Discard
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		_ = stdin.Close()
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		_ = stdin.Close()
		return nil, err
	}
	process := &codexProcess{
		cmd:        cmd,
		stdin:      stdin,
		lines:      make(chan codexMessage, 8),
		stop:       make(chan struct{}),
		readerDone: make(chan struct{}),
	}
	go func() {
		defer close(process.readerDone)
		deliver := func(message codexMessage) bool {
			select {
			case process.lines <- message:
				return true
			case <-process.stop:
				return false
			}
		}
		scanner := bufio.NewScanner(stdout)
		scanner.Buffer(make([]byte, 4096), 1<<20)
		for scanner.Scan() {
			var value map[string]any
			if err := json.Unmarshal(scanner.Bytes(), &value); err != nil {
				deliver(codexMessage{err: fmt.Errorf("Codex JSON: %w", err)})
				return
			}
			if !deliver(codexMessage{value: value}) {
				return
			}
		}
		if err := scanner.Err(); err != nil {
			deliver(codexMessage{err: err})
		} else {
			deliver(codexMessage{err: io.EOF})
		}
	}()
	return process, nil
}

func sameID(value any, id int) bool {
	number, ok := value.(float64)
	return ok && number == float64(id)
}

func (p *codexProcess) call(id int, method string, params any) (map[string]any, error) {
	request := map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params}
	encoded, err := json.Marshal(request)
	if err != nil {
		return nil, err
	}
	if _, err := p.stdin.Write(append(encoded, '\n')); err != nil {
		return nil, err
	}
	deadline := time.NewTimer(15 * time.Second)
	defer deadline.Stop()
	for {
		select {
		case message := <-p.lines:
			if message.err != nil {
				return nil, message.err
			}
			if !sameID(message.value["id"], id) {
				continue
			}
			if fault, ok := message.value["error"]; ok {
				return nil, fmt.Errorf("Codex %s error: %v", method, fault)
			}
			result, ok := message.value["result"].(map[string]any)
			if !ok {
				return nil, fmt.Errorf("Codex %s returned no result", method)
			}
			return result, nil
		case <-deadline.C:
			return nil, fmt.Errorf("Codex %s timed out", method)
		}
	}
}

func (p *codexProcess) close() error {
	p.stopOnce.Do(func() { close(p.stop) })
	_ = p.stdin.Close()
	if p.cmd.Process == nil {
		<-p.readerDone
		return nil
	}
	_ = p.cmd.Process.Signal(syscall.SIGTERM)
	done := make(chan error, 1)
	go func() { done <- p.cmd.Wait() }()
	select {
	case err := <-done:
		<-p.readerDone
		return err
	case <-time.After(5 * time.Second):
		_ = p.cmd.Process.Kill()
		err := <-done
		<-p.readerDone
		return err
	}
}

func hooksFromResult(result map[string]any) ([]map[string]any, error) {
	data, ok := result["data"].([]any)
	if !ok || len(data) == 0 {
		return nil, errors.New("Codex hooks/list returned no data")
	}
	first, ok := data[0].(map[string]any)
	if !ok {
		return nil, errors.New("Codex hooks/list returned malformed data")
	}
	rawHooks, ok := first["hooks"].([]any)
	if !ok {
		return nil, errors.New("Codex hooks/list returned no hooks")
	}
	hooks := make([]map[string]any, 0, len(rawHooks))
	for _, raw := range rawHooks {
		hook, ok := raw.(map[string]any)
		if !ok {
			return nil, errors.New("Codex hooks/list returned a malformed hook")
		}
		hooks = append(hooks, hook)
	}
	return hooks, nil
}

func run() error {
	runtime := flag.String("runtime", defaultRuntime, "Bee runtime executable")
	codex := flag.String("codex", defaultCodex, "installed Codex executable")
	rootFlag := flag.String("root", ".", "Bee repository root")
	flag.Parse()
	repo, err := filepath.Abs(*rootFlag)
	if err != nil {
		return err
	}
	runtimePath, err := filepath.Abs(*runtime)
	if err != nil {
		return err
	}
	if _, err := os.Stat(runtimePath); err != nil {
		return err
	}
	if _, err := exec.LookPath(*codex); err != nil {
		return fmt.Errorf("Codex executable unavailable: %w", err)
	}
	fixtureRoot, err := os.MkdirTemp("", ".bee-codex-production-hooks-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(fixtureRoot)
	mcp := newMCPFixture()
	defer mcp.server.Close()
	if err := writeFixture(fixtureRoot, mcp.server.Listener.Addr().(*net.TCPAddr).Port, repo); err != nil {
		return err
	}
	env := environment(fixtureRoot)
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	emit := exec.CommandContext(ctx, runtimePath, "run", "emit")
	emit.Dir, emit.Env = fixtureRoot, env
	if output, err := emit.CombinedOutput(); err != nil {
		return fmt.Errorf("production configuration.lua execution: %w\n%s", err, output)
	}
	var flags []string
	argsFile := filepath.Join(fixtureRoot, "args.json")
	args, err := os.ReadFile(argsFile)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(args, &flags); err != nil {
		return fmt.Errorf("decode emitted Codex flags: %w", err)
	}
	if len(flags) == 0 || len(flags)%2 != 0 {
		return fmt.Errorf("unexpected emitted Codex flags: %v", flags)
	}
	model := newRejectingModelFixture()
	defer model.Close()
	configPath := filepath.Join(fixtureRoot, "home", "config.toml")
	config := []byte(fmt.Sprintf(`model_provider="fixture"
model="fixture"
[model_providers.fixture]
name="Fixture"
base_url=%q
wire_api="responses"
requires_openai_auth=false
[[hooks.SessionStart]]
[[hooks.SessionStart.hooks]]
type="command"
command="printf user_fixture"
`, model.URL))
	if err := os.WriteFile(configPath, config, 0600); err != nil {
		return err
	}
	original, err := os.ReadFile(configPath)
	if err != nil {
		return err
	}
	process, err := startCodex(*codex, fixtureRoot, env, append(flags, "app-server", "--stdio"))
	if err != nil {
		return err
	}
	defer process.close()
	if _, err := process.call(1, "initialize", map[string]any{"clientInfo": map[string]any{"name": "bee_production_hook_proof", "version": "1"}, "capabilities": map[string]any{"experimentalApi": true}}); err != nil {
		return err
	}
	hooksResult, err := process.call(2, "hooks/list", map[string]any{"cwds": []string{fixtureRoot}})
	if err != nil {
		return err
	}
	hooks, err := hooksFromResult(hooksResult)
	if err != nil {
		return err
	}
	beeHooks := 0
	userHook := false
	for _, hook := range hooks {
		if hook["source"] == "sessionFlags" && hook["trustStatus"] == "trusted" {
			beeHooks++
		}
		if hook["command"] == "printf user_fixture" {
			userHook = true
		}
	}
	if beeHooks != 5 || !userHook {
		return fmt.Errorf("Codex hooks did not preserve trusted Bee hooks and user hook: %#v", hooks)
	}
	thread, err := process.call(3, "thread/start", map[string]any{"cwd": fixtureRoot, "approvalPolicy": "never"})
	if err != nil {
		return err
	}
	threadValue, ok := thread["thread"].(map[string]any)
	if !ok || threadValue["id"] == nil {
		return errors.New("Codex thread/start returned no thread ID")
	}
	if _, err := process.call(4, "turn/start", map[string]any{"threadId": threadValue["id"], "input": []any{map[string]any{"type": "text", "text": "Fixture only."}}}); err != nil {
		return err
	}
	deadline := time.Now().Add(8 * time.Second)
	var observed *hookObservation
	for time.Now().Before(deadline) {
		for _, item := range mcp.observations() {
			if item.method == "tools/call" {
				copy := item
				observed = &copy
				break
			}
		}
		if observed != nil {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if observed == nil || !observed.authorized {
		return fmt.Errorf("authenticated SessionStart MCP hook was not observed: %#v", mcp.observations())
	}
	arguments, ok := observed.params["arguments"].(map[string]any)
	if !ok || arguments["event"] != "SessionStart" || arguments["session_id"] == nil {
		return fmt.Errorf("malformed SessionStart hook arguments: %#v", observed.params)
	}
	final, err := os.ReadFile(configPath)
	if err != nil {
		return err
	}
	if string(final) != string(original) {
		return errors.New("Codex changed the existing global fixture config")
	}
	fmt.Println("PASS: production Codex configuration emitted scoped MCP and five trusted hooks, retained the existing user hook, authenticated SessionStart, and made no real model/API call")
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
