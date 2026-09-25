// SPDX-License-Identifier: MIT
// Source acceptance for a managed Agent launch failure. The fixture injects a
// post-admission preparation refusal after the picker has admitted the request,
// then keeps the failure surface open while its settlement receipt is slow.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"gopkg.in/yaml.v3"
)

const failureLua = `local process = require("process")
local channel = require("channel")
local time = require("time")
local security = require("security")
local tty = require("tty")
local funcs = require("funcs")
local appearance = require("appearance")
local admission = require("admission")
local registry = require("registry")
local fs = require("fs")
local placement_store = require("placement_store")

local function reply(value: unknown): {[string]: unknown}
    if type(value) ~= "table" then error("missing reply") end
    return value :: {[string]: unknown}
end
local function apply(entry: {[string]: unknown})
    local changes = registry.snapshot():changes()
    changes:update(entry)
    assert(changes:apply())
end
local function changed(entry: {[string]: unknown}): {[string]: unknown}
    local result: {[string]: unknown} = {}
    for key, value in pairs(entry) do result[key] = value end
    local data: {[string]: unknown} = {}
    for key, value in pairs(entry.data :: {[string]: unknown}) do data[key] = value end
    result.data = data
    return result
end
local function call(target: string, value: unknown): {[string]: unknown}
    local raw, call_error = funcs.call(target, value)
    if call_error then error(target .. ": " .. tostring(call_error)) end
    local result = reply(raw)
    if result.ok ~= true then
        local fault = type(result.error) == "table" and result.error :: {[string]: unknown} or {}
        error(target .. ": " .. tostring(fault.code) .. ": " .. tostring(fault.message))
    end
    return result
end
local WORKSPACE = string.rep("a", 32)
local STAGE = "admitted"
local BEFORE_ADMISSION = STAGE == "plan" or STAGE == "component"

local function run()
    local thread = "managed_window_selector"
    call("bee.threads.service:create", {thread_id = thread, idempotency_key = "managed-window-failure-create", title = "Managed window failure fixture"})
    local owner = tostring(process.pid())
    local catalogs = assert(process.listen("bee.application.catalog", {message = true}))
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local appearance_requests = assert(process.listen("bee.appearance.request", {message = true}))
    local broker_policy = assert(security.policy("bee.security.desktop:broker_policy"))
    local boundary = assert(security.policy("bee.security:core_spawn_boundary"))
    local broker = tostring(assert(process.with_context({["bee.workspace_owner"] = owner, ["bee.workspace_id"] = WORKSPACE})
        :with_scope(security.new_scope({broker_policy, boundary})):spawn_monitored("bee.applications:broker", "bee:workers", owner,
            {theme = "classic", background = "solid", taskbar = "labels"})))
    local events = assert(process.events())
    local appearance_replies = 0
    coroutine.spawn(function()
        while true do
            local selected = channel.select({appearance_requests:case_receive(), events:case_receive()})
            if not selected.ok or selected.channel == events then return end
            local message = selected.value
            local data: unknown = message:payload():data()
            if tostring(message:from()) == broker and type(data) == "table" and data.version == 1
                and data.op == "appearance" and data.action == "state" then
                appearance_replies = appearance_replies + 1
                assert(process.send(broker, "bee.appearance.state", {version = 1, request_id = data.request_id,
                    revision = appearance_replies, theme = "classic", background = "solid", taskbar = "labels",
                    error_code = "", error = ""}))
            end
        end
    end)
    local deadline = time.after("5s")
    local ready = false
    while not ready do
        local selected = channel.select({catalogs:case_receive(), events:case_receive(), deadline:case_receive()})
        assert(selected.ok and selected.channel ~= deadline, "broker catalog timed out")
        if selected.channel == catalogs then ready = true
        elseif selected.value.kind == process.event.EXIT then error("broker exited before catalog") end
    end
    local selector = assert(registry.get("bee.managed_window_fixture:selector_definition"))
    local found = assert(registry.find({["meta.type"] = "bee.launch_definition"}))
    for _, entry in ipairs(found) do
        local meta = entry.meta :: {[string]: unknown}
        if meta.test_support ~= true then
            local hidden = changed(entry)
            hidden.data.presentation = {start_menu = false, fullscreen = false, reuse = "never"}
            apply(hidden)
        end
    end
    local hidden = changed(selector)
    hidden.data.presentation = {start_menu = false, fullscreen = false, reuse = "never"}
    apply(hidden)
    local plan, refused = admission.resolve("bee.managed_window_fixture:selector_definition", "window")
    assert(plan, tostring(refused and refused.error))
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "open", op = "open", workspace_id = WORKSPACE,
        definition_id = "bee.harness.window:app", arguments = {}}))
    local opened
    local open_deadline = time.after("5s")
	while not opened do
		local selected = channel.select({replies:case_receive(), events:case_receive(), open_deadline:case_receive()})
		assert(selected.ok and selected.channel ~= open_deadline, "open reply timed out")
        if selected.channel == replies and tostring(selected.value:from()) == broker then
            local data = selected.value:payload():data()
            if type(data) == "table" and data.request_id == "open" and data.op == "open" then opened = data end
        end
    end
    assert(opened.error_code == "", tostring(opened.error))
    -- A picker open stays threadless, so the thread owner admits the
    -- host-issued principal of the exact instance the open reported.
    local head = (call("bee.threads.service:get", {thread_id = thread}).value :: {[string]: unknown}).summary :: {[string]: unknown}
    call("bee.threads.service:join", {thread_id = thread, idempotency_key = "managed-window-failure-join",
        member_id = "bee.application:" .. WORKSPACE .. ":" .. tostring(opened.instance_id), role = "participant", expected_revision = head.revision})
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "bind", op = "bind", workspace_id = WORKSPACE,
        id = opened.id, instance_id = opened.instance_id, recipient = owner}))
    local mounted = ""
    local bind_deadline = time.after("5s")
	while mounted == "" do
		local selected = channel.select({replies:case_receive(), events:case_receive(), bind_deadline:case_receive()})
		assert(selected.ok and selected.channel ~= bind_deadline, "bind reply timed out")
        if selected.channel == replies and tostring(selected.value:from()) == broker then
            local data = selected.value:payload():data()
            if type(data) == "table" and data.request_id == "bind" and data.op == "attached" then
                assert(data.error_code == "", tostring(data.error))
                mounted = tostring(data.mount)
            end
        end
    end
    local view = assert(tty.attach(mounted))
    assert(view:send({type = "resize", width = 100, height = 10}))
    apply(selector)
    assert(view:send({type = "key", key = "r", key_type = "rune", action = "press"}))
    local listed = false
    for _ = 1, 120 do
        local frame = view:snapshot()
        if frame and table.concat(frame.rows):find("Selected agent fixture", 1, true) then listed = true; break end
        time.sleep("25ms")
    end
    assert(listed, "picker did not show fixture")
    assert(view:send({type = "key", key = "", key_type = "enter", action = "press"}))
	local failure, pending = nil, nil
	for _ = 1, 160 do
		local frame = view:snapshot()
		if frame then
			local text = table.concat(frame.rows)
			if text:find("Agent launch failed", 1, true) then
				if not failure then failure = frame end
                if BEFORE_ADMISSION and appearance_replies > 0 then break end
				if text:find("settlement pending", 1, true) then pending = frame; break end
			end
		end
		time.sleep("25ms")
	end
	assert(failure, "failure surface did not remain visible")
    assert((pending ~= nil) == (not BEFORE_ADMISSION), "incorrect settlement scope")
    local failure_text = table.concat(failure.rows)
	assert(failure_text:find(STAGE == "component" and "window component" or (STAGE == "generation" and "attachment generation" or "injected"), 1, true), "failure reason missing")
    assert(appearance_replies > 0, "broker did not receive authenticated appearance state response")
    assert(view:send({type = "resize", width = 70, height = 14}))
    local resized = false
    for _ = 1, 40 do
        local frame = view:snapshot()
        if frame and #frame.rows == 14 then resized = true; break end
        time.sleep("25ms")
    end
    assert(resized, "failure surface did not resize while settling")
    local records = call("bee.threads.service:read_after", {thread_id = thread, cursor = 0, limit = 32}).value.records
    local admitted, prepared = 0, 0
    local attempt_id = ""
    for _, record in ipairs(records :: {{[string]: unknown}}) do
        if record.kind == "action.admitted" then admitted = admitted + 1 end
        if record.kind == "attempt.prepared" then prepared = prepared + 1; attempt_id = tostring(record.attempt_id) end
        assert(record.kind ~= "attempt.started", "failed launch started a thread attempt")
        if BEFORE_ADMISSION then assert(record.kind ~= "receipt", "planning failure wrote a receipt") end
    end
    assert(admitted == (BEFORE_ADMISSION and 0 or 1), "incorrect action admission count")
    assert(prepared == ((STAGE == "placement" or STAGE == "generation") and 1 or 0), "incorrect attempt preparation count")
    if STAGE == "placement" or STAGE == "generation" then
        local cleaned = false
        -- The attempt belongs to the window's launch principal, so its
        -- cleanup is read through the fixture's own store access.
        for _ = 1, 80 do
            local status_db = assert(placement_store.open())
            local attempt = assert(placement_store.attempt(status_db, attempt_id), "prepared placement attempt is missing")
            status_db:release()
            if attempt.execution_state == "exited" and attempt.cleanup_state == "complete" then
                assert(attempt.runner == nil, "refused window created a runner")
                cleaned = true; break
            end
            time.sleep("25ms")
        end
        assert(cleaned, "refused window retained the unstarted placement")
    end
    time.sleep("250ms")
    assert(view:snapshot(), "failure surface auto-dismissed before explicit close")
    assert(view:send({type = "key", key = "", key_type = "escape", action = "press"}))
    time.sleep("250ms")
    assert(not view:snapshot(), "Escape did not dismiss failure surface")
    view:close()
    process.terminate(broker)
    process.unlisten(catalogs); process.unlisten(replies); process.unlisten(appearance_requests)
    local evidence = assert(fs.get("bee.managed_window_fixture:failure_evidence"))
    local proof = assert(evidence:open("/complete", "w"))
    assert(proof:write("MANAGED_WINDOW_FAILURE_COMPLETE"))
    proof:close()
end
return {run = run}
`

const failureDriverLua = `local M = {}
function M.prepare(value: unknown): {[string]: unknown}
    return {ok = true, launch = {executable = "sh", argv = {"-c", "true"}, environment = {}, readiness = "none"}}
end
function M.dispatch(_: unknown): {[string]: unknown} return {ok = false, error = "unused"} end
function M.normalize(_: unknown): {[string]: unknown} return {ok = false, error = "unused"} end
function M.configure(_: unknown): {[string]: unknown} return {ok = true, delivery = {arguments = {}, files = {}}} end
return M
`

type fixtureIndex struct {
	Version   string                   `yaml:"version"`
	Namespace string                   `yaml:"namespace"`
	Entries   []map[string]interface{} `yaml:"entries"`
}

func copyTree(dst, src string) error { return os.CopyFS(dst, os.DirFS(src)) }

func runCommand(ctx context.Context, dir, runtime string, env []string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, runtime, args...)
	cmd.Dir, cmd.Env = dir, append(os.Environ(), env...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return nil
		}
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
	cmd.WaitDelay = 3 * time.Second
	return cmd.CombinedOutput()
}

func envFor(dir string) []string {
	names := []string{"workspace", "threads", "approvals", "resources", "credentials", "placement", "gateway", "node", "governance"}
	env := []string{"HOME=" + filepath.Join(dir, "home"), "XDG_CONFIG_HOME=" + filepath.Join(dir, "config"), "XDG_DATA_HOME=" + filepath.Join(dir, "data"), "XDG_STATE_HOME=" + filepath.Join(dir, "state")}
	for _, name := range names {
		env = append(env, "BEE_"+strings.ToUpper(name)+"_DB="+filepath.Join(dir, name+".db"))
	}
	return env
}

func run() error {
	runtime := flag.String("runtime", ".wippy/bin/bee-wippy", "Bee runtime executable")
	root := flag.String("root", ".", "Bee repository root")
	stage := flag.String("stage", "admitted", "failure stage: plan, component, admitted, placement or generation")
	flag.Parse()
	if *stage != "plan" && *stage != "admitted" && *stage != "placement" && *stage != "component" && *stage != "generation" {
		return fmt.Errorf("unknown failure stage %q", *stage)
	}
	repo, err := filepath.Abs(*root)
	if err != nil {
		return err
	}
	runtimePath, err := filepath.Abs(*runtime)
	if err != nil {
		return err
	}
	if _, err := os.Stat(runtimePath); err != nil {
		return fmt.Errorf("runtime %s: %w", runtimePath, err)
	}
	dir, err := os.MkdirTemp("", "bee-managed-window-failure-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	if err := copyTree(filepath.Join(dir, "src"), filepath.Join(repo, "src")); err != nil {
		return err
	}
	if err := copyTree(filepath.Join(dir, "modules"), filepath.Join(repo, "modules")); err != nil {
		return err
	}
	fixture := filepath.Join(dir, "src", "tests", "managed_window_app")
	if err := copyTree(fixture, filepath.Join(repo, "tests", "fixtures", "managed_window_app")); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(fixture, "driver.lua"), []byte(failureDriverLua), 0600); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(fixture, "failure.lua"), []byte(strings.Replace(failureLua, `local STAGE = "admitted"`, `local STAGE = "`+*stage+`"`, 1)), 0600); err != nil {
		return err
	}
	indexPath := filepath.Join(fixture, "_index.yaml")
	indexData, err := os.ReadFile(indexPath)
	if err != nil {
		return err
	}
	var index fixtureIndex
	if err := yaml.Unmarshal(indexData, &index); err != nil {
		return err
	}
	kept := make([]map[string]interface{}, 0, len(index.Entries))
	for _, entry := range index.Entries {
		name, _ := entry["name"].(string)
		if name == "natural_completion_test" || name == "checkpoint_ack_test" || name == "selector_test" || name == "retained_test" {
			continue
		}
		if name == "test" {
			entry["source"], entry["method"] = "file://failure.lua", "run"
			entry["imports"].(map[string]interface{})["placement_store"] = "bee.placement.native:store"
			entry["security"].(map[string]interface{})["policies"] = append(entry["security"].(map[string]interface{})["policies"].([]interface{}), "bee.security.placement:placement_store_policy", "bee.managed_window_fixture:failure_evidence_policy")
		}
		kept = append(kept, entry)
	}
	index.Entries = append(kept,
		map[string]interface{}{"name": "failure_evidence", "kind": "fs.directory", "directory": "evidence", "auto_init": true},
		map[string]interface{}{"name": "failure_evidence_policy", "kind": "security.policy", "policy": map[string]interface{}{"actions": []string{"fs.get"}, "resources": []string{"bee.managed_window_fixture:failure_evidence"}, "effect": "allow"}},
	)
	indexData, err = yaml.Marshal(&index)
	if err != nil {
		return err
	}
	if err := os.WriteFile(indexPath, indexData, 0600); err != nil {
		return err
	}
	hostPath := filepath.Join(dir, "src", "harness", "host", "_index.yaml")
	host, err := os.ReadFile(hostPath)
	if err != nil {
		return err
	}
	const activation = "    - bee.driver.grok:binding\n"
	updated := strings.Replace(string(host), activation, activation+"    - bee.managed_window_fixture:binding\n", 1)
	if updated == string(host) {
		return fmt.Errorf("host activation anchor missing")
	}
	if err := os.WriteFile(hostPath, []byte(updated), 0600); err != nil {
		return err
	}
	hostData, err := os.ReadFile(hostPath)
	if err != nil {
		return err
	}
	rootIndex := strings.TrimRight(string(hostData), "\n") + "\n- name: test_dependency\n  kind: ns.dependency\n  component: wippy/test\n  version: 0.4.17\n"
	if err := os.WriteFile(hostPath, []byte(rootIndex), 0600); err != nil {
		return err
	}
	receiptPath := filepath.Join(dir, "modules", "threads", "src", "service", "receipt_method.lua")
	receipt, err := os.ReadFile(receiptPath)
	if err != nil {
		return err
	}
	receiptText := string(receipt)
	receiptText = strings.Replace(receiptText, "local types = require(\"types\")", "local types = require(\"types\")\nlocal time = require(\"time\")", 1)
	receiptText = strings.Replace(receiptText, "    return boundary.run(lifecycle.receipt, request, true)", "    if type(request) == \"table\" and (request :: {[string]: unknown}).action_id ~= nil then time.sleep(\"2s\") end\n    return boundary.run(lifecycle.receipt, request, true)", 1)
	if receiptText == string(receipt) {
		return fmt.Errorf("receipt injection anchors missing")
	}
	if err := os.WriteFile(receiptPath, []byte(receiptText), 0600); err != nil {
		return err
	}
	receiptIndexPath := filepath.Join(dir, "modules", "threads", "src", "service", "_index.yaml")
	receiptIndex, err := os.ReadFile(receiptIndexPath)
	if err != nil {
		return err
	}
	receiptIndexText := strings.Replace(string(receiptIndex), "source: file://receipt_method.lua\n  method: handle\n", "source: file://receipt_method.lua\n  method: handle\n  modules: [time]\n", 1)
	if receiptIndexText == string(receiptIndex) {
		return fmt.Errorf("receipt module anchor missing")
	}
	if err := os.WriteFile(receiptIndexPath, []byte(receiptIndexText), 0600); err != nil {
		return err
	}
	machinePath := filepath.Join(dir, "modules", "harness", "src", "carrier", "machine.lua")
	machine, err := os.ReadFile(machinePath)
	if err != nil {
		return err
	}
	machineText := strings.Replace(string(machine), "    step(io, \"admitted\")\n", "    step(io, \"admitted\")\n    if request.binding_ref == \"bee.managed_window_fixture:binding\" then return nil, \"injected post-admission preparation failure\", {epoch = nil, gateway_binding = nil, attempt = false} end\n", 1)
	if *stage == "plan" {
		machineText = strings.Replace(string(machine), "function M.plan(io: IO, request: Request): (Plan?, string?)\n", "function M.plan(io: IO, request: Request): (Plan?, string?)\n    if request.binding_ref == \"bee.managed_window_fixture:binding\" then return nil, \"injected planning failure\" end\n", 1)
	} else if *stage == "placement" {
		runtimePath := filepath.Join(dir, "modules", "harness", "src", "window", "runtime.lua")
		runtimeSource, readError := os.ReadFile(runtimePath)
		if readError != nil {
			return readError
		}
		changed := strings.Replace(string(runtimeSource), "local checkpointed, checkpoint_error = persist_checkpoint(state)", "local checkpointed, checkpoint_error = false, \"injected checkpoint failure\"", 1)
		if changed == string(runtimeSource) {
			return fmt.Errorf("checkpoint injection anchor missing")
		}
		if err := os.WriteFile(runtimePath, []byte(changed), 0600); err != nil {
			return err
		}
		machineText = string(machine)
	}
	if *stage == "generation" {
		runtimePath := filepath.Join(dir, "modules", "harness", "src", "window", "runtime.lua")
		runtimeSource, err := os.ReadFile(runtimePath)
		if err != nil {
			return err
		}
		changed := strings.Replace(string(runtimeSource), "generation = prepared.epoch})", "generation = prepared.epoch + 1})", 1)
		if changed == string(runtimeSource) {
			return fmt.Errorf("window generation anchor missing")
		}
		if err := os.WriteFile(runtimePath, []byte(changed), 0600); err != nil {
			return err
		}
		machineText = string(machine)
	}
	if *stage == "component" {
		appPath := filepath.Join(dir, "modules", "harness", "src", "window", "app.lua")
		appSource, err := os.ReadFile(appPath)
		if err != nil {
			return err
		}
		changed := strings.Replace(string(appSource), `"bee.placement.native:binding"`, `"fixture.other:binding"`, 1)
		if changed == string(appSource) {
			return fmt.Errorf("component binding anchor missing")
		}
		if err := os.WriteFile(appPath, []byte(changed), 0600); err != nil {
			return err
		}
		machineText = string(machine)
	}
	if *stage != "placement" && *stage != "component" && *stage != "generation" && machineText == string(machine) {
		return fmt.Errorf("machine admission anchor missing")
	}
	if err := os.WriteFile(machinePath, []byte(machineText), 0600); err != nil {
		return err
	}
	config, err := os.ReadFile(filepath.Join(repo, ".wippy.yaml"))
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, ".wippy.yaml"), config, 0600); err != nil {
		return err
	}
	lock, err := os.ReadFile(filepath.Join(repo, "wippy.lock"))
	if err != nil {
		return err
	}
	dependencies, err := os.ReadFile(filepath.Join(repo, "tests", "dependencies.yaml"))
	if err != nil {
		return err
	}
	// The root lock already selects Bee's physical modules; the test framework
	// modules join that same list.
	var lockDocument map[string]interface{}
	if err := yaml.Unmarshal(lock, &lockDocument); err != nil {
		return fmt.Errorf("decode wippy.lock: %w", err)
	}
	var dependencyDocument struct {
		Modules []interface{} `yaml:"modules"`
	}
	if err := yaml.Unmarshal(dependencies, &dependencyDocument); err != nil {
		return fmt.Errorf("decode tests/dependencies.yaml: %w", err)
	}
	selected, _ := lockDocument["modules"].([]interface{})
	lockDocument["modules"] = append(selected, dependencyDocument.Modules...)
	lockText, err := yaml.Marshal(lockDocument)
	if err != nil {
		return fmt.Errorf("encode wippy.lock: %w", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "wippy.lock"), lockText, 0600); err != nil {
		return err
	}
	for _, name := range []string{"home", "config", "data", "state"} {
		if err := os.MkdirAll(filepath.Join(dir, name), 0700); err != nil {
			return err
		}
	}
	env := envFor(dir)
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	if out, err := runCommand(ctx, dir, runtimePath, env, "install"); err != nil {
		return fmt.Errorf("staged dependency install failed: %w\n%s", err, out)
	}
	if out, err := runCommand(ctx, dir, runtimePath, env, "lint"); err != nil {
		return fmt.Errorf("staged lint failed: %w\n%s", err, out)
	}
	out, err := runCommand(ctx, dir, runtimePath, env, "test", "--host", "bee:terminal")
	if err != nil {
		return fmt.Errorf("failure acceptance failed: %w\n%s", err, out)
	}
	proof, proofError := os.ReadFile(filepath.Join(dir, "evidence", "complete"))
	if proofError != nil || string(proof) != "MANAGED_WINDOW_FAILURE_COMPLETE" {
		return fmt.Errorf("failure acceptance omitted test output\n%s", out)
	}
	fmt.Printf("Managed window failure %s: visible reason, correct lifecycle scope, authenticated appearance, resize, explicit close and completion proof passed\n", *stage)
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
