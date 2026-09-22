// SPDX-License-Identifier: MIT
// Explicit live-provider acceptance; intentionally outside the default check.
// A saved Codex agent profile that names one Codex config profile must reach
// its model and do real work inside Bee: one real turn that answers a prompt
// whose answer cannot be guessed, committed to the bound thread as an
// observation. The provider is selected by the owner's own Codex config
// profile, never by a fixture; no credential bytes are read or printed.
package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	_ "github.com/mattn/go-sqlite3"
	"gopkg.in/yaml.v3"
)

// The probe fixture composes the production launch, carrier and thread owners
// around a test-owned command entry. Only the command entry and the named
// Codex profile are test-owned.
const liveCodexProbeIndex = `version: '1.0'
namespace: bee.live_codex_profile
entries:
- name: host_policy
  kind: security.policy
  policy: {actions: ['*'], resources: ['*'], effect: allow}
- name: environment
  kind: env.storage.os
  lifecycle: {auto_start: true}
- name: token
  kind: env.variable
  storage: bee.live_codex_profile:environment
  variable: BEE_LIVE_CODEX_TOKEN
  readonly: true
- name: config_profile
  kind: env.variable
  storage: bee.live_codex_profile:environment
  variable: BEE_LIVE_CODEX_PROFILE
  readonly: true
- name: main
  kind: process.lua
  source: file://main.lua
  method: main
  modules: [funcs, process, channel, time, json, sql, uuid, env]
  imports: {bounds: bee.threads.records:bounds}
  security: {policies: [bee.live_codex_profile:host_policy]}
  meta:
    command:
      name: live-codex-profile
      security: {actor: {id: bee.live_codex_profile.probe}}
`

const liveCodexProbeMain = `-- SPDX-License-Identifier: MIT
-- One live turn through a saved Codex profile that names a Codex config
-- profile. The token is supplied by the harness and never appears in argv or
-- any provider configuration; the agent must read it back from its own bound
-- thread through the Bee MCP, so a canned or fixture answer cannot satisfy it.
local funcs = require("funcs")
local process = require("process")
local channel = require("channel")
local time = require("time")
local json = require("json")
local sql = require("sql")
local uuid = require("uuid")
local env = require("env")
local bounds = require("bounds")
type Object = {[string]: unknown}
local function reply(target: string, request: unknown): Object
    local result, err = funcs.call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    local reply = bounds.object(result)
    if not reply then error("missing reply from " .. target) end
    if reply.ok ~= true then error(target .. ": " .. tostring(json.encode(reply.error))) end
    return reply
end
local function call(target: string, request: unknown): Object
    local result = bounds.object(reply(target, request).value)
    if not result then error("missing value from " .. target) end
    return result
end
local function main()
    local actor = "bee.live_codex_profile.probe"
    local definition = "bee.driver.codex:named_batch"
    local config_profile = env.get("bee.live_codex_profile:config_profile")
    if type(config_profile) ~= "string" or config_profile == "" then config_profile = "ds-flash" end
    local token = env.get("bee.live_codex_profile:token")
    if type(token) ~= "string" or token == "" then error("missing probe token") end
    local workspace_id = "live-codex-profile"
    local thread_id = "live-codex-profile-thread"
    -- A listener must exist before admission mints a gateway binding.
    local listener: Object? = nil
    for _ = 1, 150 do
        local raw, address_error = funcs.call("bee.gateway.registry:address", {})
        if not address_error then listener = bounds.object(raw) end
        if listener and type(listener.address) == "string" then break end
        time.sleep("100ms")
    end
    if not listener or type(listener.address) ~= "string" then error("native MCP listener did not become ready") end
    -- Save the profile that names the Codex config profile.
    local profile_id = "live-codex-profile-" .. tostring(uuid.v7())
    call("bee.harness.profiles:call", {operation = "put", workspace_id = workspace_id, profile_id = profile_id,
        expected_revision = 0, idempotency_key = "save-" .. profile_id,
        profile = {title = "Live Codex named profile", definition_ref = definition, options = {config_profile = config_profile}, mcp_tools = {"thread_read"}}})
    local plan = call("bee.harness.launch:resolve", {definition_ref = definition, workspace_id = workspace_id,
        saved_profile_id = profile_id, saved_profile_revision = 1})
    reply("bee.harness.launch:setup", {workspace_id = workspace_id, definition_ref = definition,
        saved_profile_id = profile_id, saved_profile_revision = 1, expected_plan_digest = plan.plan_digest})
    call("bee.threads.service:create", {thread_id = thread_id, idempotency_key = "create-live-codex", title = "Live Codex named profile proof"})
    -- The token is committed as an observation of the bound thread; the agent
    -- must read it back through the Bee MCP, so the answer is unguessable and
    -- cannot be a canned or fixture response.
    -- Seeded on the progress channel from the MCP source so only the agent's
    -- own stream answer can satisfy the check.
    local event: Object = {type = "text", segment_id = "live-codex-token", operation = "complete", text = token, channel = "progress"}
    call("bee.threads.service:record", {thread_id = thread_id, idempotency_key = "seed-" .. token, kind = "observation", source = "mcp",
        body = {type = "text", event_key = "live-codex-seed", data = event}})
    local brief = "Read your bound Bee thread with the thread_read MCP tool. Find the text observation whose text is a single short token, then reply with exactly that token and nothing else."
    local started = call("bee.harness.launch:start", {request_id = "live-codex-" .. profile_id, definition_ref = definition,
        workspace_id = workspace_id, thread_id = thread_id, brief = brief, saved_profile_id = profile_id,
        saved_profile_revision = 1, expected_plan_digest = plan.plan_digest})
    local pid = tostring(started.carrier)
    local monitored, monitor_error = process.monitor(pid)
    if not monitored then error(tostring(monitor_error)) end
    local events = process.events()
    if not events then error("process events unavailable") end
    local deadline = time.after("300s")
    while true do
        local selected = channel.select({events:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then error("live Codex carrier exceeded 300s") end
        local item = selected.value
        if selected.channel == events and item.kind == process.event.EXIT and tostring(item.from) == pid then
            if item.result and item.result.error then error("live carrier failed: " .. tostring(item.result.error)) end
            break
        end
    end
    -- The attempt must settle successfully and the answer must be an
    -- observation committed to the thread.
    local db, db_error = sql.get("bee.placement.native:db")
    if not db then error(tostring(db_error)) end
    local rows, query_error = db:query("SELECT execution_state, exit_code FROM bee_placement_attempts WHERE attempt_id = ?", {started.attempt_id})
    db:release()
    if query_error or not rows or #rows ~= 1 then error("missing placement attempt") end
    local attempt = bounds.object(rows[1])
    if not attempt then error("invalid placement attempt row") end
    if tostring(attempt.execution_state) ~= "exited" then error("attempt did not settle: " .. tostring(attempt.execution_state)) end
    local cursor = 0
    local answered = false
    local receipted = false
    for _ = 1, 64 do
        local page = call("bee.threads.service:read_after", {thread_id = thread_id, cursor = cursor, limit = 64})
        local records = page.records
        if type(records) ~= "table" then error("thread page records missing") end
        for _, raw in ipairs(records) do
            local record = bounds.object(raw)
            if record and record.source == "stream" then
                -- An observation body carries its typed payload under data.
                local body = bounds.object(record.body)
                local payload = body and bounds.object(body.data)
                if payload and payload.type == "text" and tostring(payload.text) == token and tostring(payload.channel) == "answer" then
                    answered = true
                end
            end
            if record and record.kind == "receipt" then receipted = true end
        end
        if page.has_more ~= true then break end
        local next_cursor = bounds.count(page.scanned_through)
        if not next_cursor or next_cursor <= cursor then error("invalid page progress") end
        cursor = next_cursor
    end
    if not receipted then error("the attempt recorded no receipt") end
    if not answered then error("the agent did not commit the exact token as a stream observation") end
    print("LIVE_CODEX_PROFILE_PASS profile=" .. config_profile .. " token=" .. token .. " attempt=" .. tostring(started.attempt_id))
    return {ok = true, action_id = started.action_id, attempt_id = started.attempt_id, token = token}
end
return {main = main}
`

func liveCodexRun(ctx context.Context, directory, runtime string, environment []string, args ...string) ([]byte, error) {
	command := exec.CommandContext(ctx, runtime, args...)
	command.Dir, command.Env = directory, environment
	command.Cancel = func() error { return command.Process.Signal(os.Interrupt) }
	command.WaitDelay = 15 * time.Second
	return command.CombinedOutput()
}

func liveCodexWrite(path, content string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(content), 0600)
}

func liveCodexCopy(dst, src string) error {
	return os.CopyFS(dst, os.DirFS(src))
}

func liveCodexCheck() error {
	source := flag.String("root", "..", "Bee source root")
	selectedRuntime := flag.String("runtime", "", "native runtime executable")
	selectedCodex := flag.String("codex", "codex", "installed Codex executable")
	selectedProfile := flag.String("profile", "", "Codex config profile name (default: $BEE_LIVE_CODEX_PROFILE or ds-flash)")
	lintOnly := flag.Bool("lint-only", false, "stage and lint without provider inference")
	flag.Parse()
	repo, err := filepath.Abs(*source)
	if err != nil {
		return err
	}
	runtime := *selectedRuntime
	if runtime == "" {
		runtime = filepath.Join(repo, ".wippy/bin/bee-wippy")
	}
	if runtime, err = filepath.Abs(runtime); err != nil {
		return err
	}
	codex, err := exec.LookPath(*selectedCodex)
	if err != nil {
		return fmt.Errorf("Codex executable unavailable: %w", err)
	}
	codex, err = filepath.Abs(codex)
	if err != nil {
		return err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	configProfile := *selectedProfile
	if configProfile == "" {
		configProfile = os.Getenv("BEE_LIVE_CODEX_PROFILE")
	}
	if configProfile == "" {
		configProfile = "ds-flash"
	}
	// Existence only: never read the profile's contents into this process.
	profileFile := filepath.Join(home, ".codex", configProfile+".config.toml")
	if _, err := os.Stat(profileFile); err != nil {
		return fmt.Errorf("named Codex config profile %s is not installed in the Codex home", configProfile)
	}
	root, err := os.MkdirTemp("", "bee-live-codex-profile-")
	if err != nil {
		return err
	}
	// Retain evidence privately, including after failure.
	fmt.Println("Private evidence:", root)
	if err = liveCodexCopy(filepath.Join(root, "src"), filepath.Join(repo, "src")); err != nil {
		return err
	}
	for _, name := range []string{".wippy.yaml", "wippy.lock"} {
		data, readErr := os.ReadFile(filepath.Join(repo, name))
		if readErr != nil {
			return readErr
		}
		if err = liveCodexWrite(filepath.Join(root, name), string(data)); err != nil {
			return err
		}
	}
	index := filepath.Join(root, "src/live_codex_profile/_index.yaml")
	if err = liveCodexWrite(index, liveCodexProbeIndex); err != nil {
		return err
	}
	if err = liveCodexWrite(filepath.Join(root, "src/live_codex_profile/main.lua"), liveCodexProbeMain); err != nil {
		return err
	}
	// The inherited Codex home and the host executable are read through this
	// host-selected OS environment storage.
	hostDirectory := filepath.Join(root, "src/live_codex_host")
	if err = os.MkdirAll(hostDirectory, 0700); err != nil {
		return err
	}
	if err = liveCodexWrite(filepath.Join(hostDirectory, "_index.yaml"),
		"version: '1.0'\nnamespace: bee.harness.host\nentries:\n- name: environment\n  kind: env.storage.os\n  lifecycle: {auto_start: true}\n"); err != nil {
		return err
	}
	// The host executes the owner's installed Codex and inherits the owner's
	// Codex home, so the named profile and its login resolve there.
	if err = liveCodexSetVariable(root, "src/driver/codex/_index.yaml", "executable", "BEE_LIVE_CODEX_EXECUTABLE"); err != nil {
		return err
	}
	if err = liveCodexSetVariable(root, "src/environment/_index.yaml", "machine_home", "BEE_LIVE_CODEX_HOME"); err != nil {
		return err
	}
	overrides := map[string]string{"BEE_LIVE_CODEX_EXECUTABLE": codex, "BEE_LIVE_CODEX_HOME": home,
		"BEE_LIVE_CODEX_PROFILE": configProfile}
	// A token whose answer cannot be guessed, unique per run.
	tokenBytes := make([]byte, 8)
	urandom, err := os.Open("/dev/urandom")
	if err != nil {
		return err
	}
	if _, err = urandom.Read(tokenBytes); err != nil {
		urandom.Close()
		return err
	}
	urandom.Close()
	token := fmt.Sprintf("BEE-%X", tokenBytes)
	overrides["BEE_LIVE_CODEX_TOKEN"] = token
	for _, name := range []string{"workspace", "threads", "approvals", "resources", "credentials", "placement", "gateway", "node", "governance", "sync", "client"} {
		overrides["BEE_"+strings.ToUpper(name)+"_DB"] = filepath.Join(root, name+".db")
	}
	environment := []string{}
	for _, item := range os.Environ() {
		key, _, _ := strings.Cut(item, "=")
		if _, replaced := overrides[key]; !replaced {
			environment = append(environment, item)
		}
	}
	for key, value := range overrides {
		environment = append(environment, key+"="+value)
	}
	lintContext, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	lint, err := liveCodexRun(lintContext, root, runtime, environment, "lint")
	if err != nil {
		return fmt.Errorf("live Codex fixture lint: %w\n%s", err, lint)
	}
	if err = liveCodexWrite(filepath.Join(root, "evidence-pass.json"), `{"stage":"lint"}`+"\n"); err != nil {
		return err
	}
	if *lintOnly {
		fmt.Println("Live Codex profile fixture lint passed; no inference performed")
		return nil
	}
	runContext, cancelRun := context.WithTimeout(context.Background(), 6*time.Minute)
	defer cancelRun()
	output, runErr := liveCodexRun(runContext, root, runtime, environment, "run",
		"--set", "registry.history_path="+filepath.Join(root, "registry.db"), "live-codex-profile")
	if writeErr := liveCodexWrite(filepath.Join(root, "run.log"), string(output)); writeErr != nil {
		return writeErr
	}
	// The turn is proven from the durable stores the run left behind, not from
	// a console banner: the attempt's recorded launch line, its settlement, and
	// the agent's own thread observation.
	for _, name := range []string{"threads.db", "placement.db", "gateway.db"} {
		if _, statErr := os.Stat(filepath.Join(root, name)); statErr != nil {
			return fmt.Errorf("run produced no %s: %v", name, statErr)
		}
	}
	proven, verifyErr := liveCodexVerify(filepath.Join(root, "placement.db"), filepath.Join(root, "threads.db"), configProfile, token)
	if verifyErr != nil {
		return fmt.Errorf("live Codex profile evidence: %w", verifyErr)
	}
	if !proven {
		// The provider's exact refusal, if any, is in the captured output.
		relevant := []string{}
		for _, line := range strings.Split(string(output), "\n") {
			if strings.Contains(line, "live_codex_profile") || strings.Contains(line, "LIVE_CODEX") || strings.Contains(line, "\tERROR\t") {
				relevant = append(relevant, line)
			}
		}
		if len(relevant) > 40 {
			relevant = relevant[len(relevant)-40:]
		}
		return fmt.Errorf("live Codex profile turn failed: %v\n%s", runErr, strings.Join(relevant, "\n"))
	}
	evidence, err := json.MarshalIndent(map[string]interface{}{
		"passed":  true,
		"proof":   "a saved Codex agent profile naming a Codex config profile reached its model through Bee, read its own bound thread over Bee MCP and committed the exact unguessable token as a stream observation; the turn settled succeeded with a receipt",
		"runtime": runtime, "codex": codex, "config_profile": configProfile, "token": token,
	}, "", "  ")
	if err != nil {
		return err
	}
	if err = liveCodexWrite(filepath.Join(root, "evidence.json"), string(evidence)); err != nil {
		return err
	}
	fmt.Println("LIVE_CODEX_PROFILE_PASS profile=" + configProfile + " runtime=" + runtime)
	return nil
}

// liveCodexVerify reads the run's durable stores read-only. It requires: the
// planned launch line led with --profile <name>; the attempt exited zero; and
// the bound thread carries the agent's own stream observation whose answer text
// is the exact unguessable token, with a succeeded turn and a receipt.
func liveCodexVerify(placementPath, threadsPath, configProfile, token string) (bool, error) {
	placement, err := sql.Open("sqlite3", "file:"+placementPath+"?mode=ro")
	if err != nil {
		return false, err
	}
	defer placement.Close()
	rows, err := placement.Query("SELECT request_json, execution_state, exit_code FROM bee_placement_attempts")
	if err != nil {
		return false, err
	}
	defer rows.Close()
	profileInLine := false
	exited := false
	found := false
	for rows.Next() {
		var request string
		var state string
		var code sql.NullInt64
		if err = rows.Scan(&request, &state, &code); err != nil {
			return false, err
		}
		found = true
		var decoded map[string]interface{}
		if err = json.Unmarshal([]byte(request), &decoded); err != nil {
			return false, err
		}
		launch, _ := decoded["launch"].(map[string]interface{})
		argv, _ := launch["argv"].([]interface{})
		if len(argv) >= 2 && argv[0] == "--profile" && argv[1] == configProfile {
			profileInLine = true
		}
		if state == "exited" && code.Valid && code.Int64 == 0 {
			exited = true
		}
	}
	if err = rows.Err(); err != nil {
		return false, err
	}
	if !found || !profileInLine || !exited {
		return false, nil
	}
	threads, err := sql.Open("sqlite3", "file:"+threadsPath+"?mode=ro")
	if err != nil {
		return false, err
	}
	defer threads.Close()
	records, err := threads.Query("SELECT kind, source, record_json FROM bee_thread_records ORDER BY sequence")
	if err != nil {
		return false, err
	}
	defer records.Close()
	answered := false
	receipted := false
	succeeded := false
	for records.Next() {
		var kind, source, raw string
		if err = records.Scan(&kind, &source, &raw); err != nil {
			return false, err
		}
		var decoded map[string]interface{}
		if err = json.Unmarshal([]byte(raw), &decoded); err != nil {
			return false, err
		}
		body, _ := decoded["body"].(map[string]interface{})
		data, _ := body["data"].(map[string]interface{})
		if kind == "observation" && source == "stream" && data["type"] == "text" && data["channel"] == "answer" && data["text"] == token {
			answered = true
		}
		if kind == "receipt" {
			receipted = true
		}
		if kind == "turn.end" && body["outcome"] == "succeeded" {
			succeeded = true
		}
	}
	if err = records.Err(); err != nil {
		return false, err
	}
	return answered && receipted && succeeded, nil
}

// liveCodexSetVariable repoints one env.variable entry at a harness-selected
// variable so the disposable composition reads the owner's executable and home
// without editing the production source.
func liveCodexSetVariable(root, relative, name, variable string) error {
	path := filepath.Join(root, relative)
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var document map[string]interface{}
	if err = yaml.Unmarshal(data, &document); err != nil {
		return err
	}
	entries, ok := document["entries"].([]interface{})
	if !ok {
		return fmt.Errorf("%s: entries missing", relative)
	}
	found := false
	for _, raw := range entries {
		entry, ok := raw.(map[string]interface{})
		if ok && entry["name"] == name {
			entry["variable"] = variable
			found = true
		}
	}
	if !found {
		return fmt.Errorf("%s: missing %s", relative, name)
	}
	data, err = yaml.Marshal(document)
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0600)
}

func main() {
	if err := liveCodexCheck(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
