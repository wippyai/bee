-- SPDX-License-Identifier: MIT

local test = require("test")
local bounds = require("bounds")
local registry = require("registry")
local application = require("application")
local sql = require("sql")
local process = require("process")
local channel = require("channel")
local time = require("time")
local tty = require("tty")
local uuid = require("uuid")
local json = require("json")
local recovery = require("recovery")

local WORKSPACE = string.rep("c", 32)
local DEFINITION = "bee.tests.harness:window_ready_definition"

local function apply(entry: {[string]: unknown})
    local changes = assert(registry.snapshot()):changes()
    changes:update(entry)
    assert(changes:apply())
end

local function define_tests()
    test.describe("Managed window readiness", function()
        test.it("executes a batch-only direct launch through the managed carrier", function()
            local original = assert(registry.get(DEFINITION))
            local batch = assert(registry.get(DEFINITION))
            local data = assert(bounds.object(batch.data))
            data.default_mode, data.profile_id = "batch", "batch"
            local policy_ref = "bee.tests.harness:window_ready_policy"
            local original_policy = assert(registry.get(policy_ref))
            local policy = assert(registry.get(policy_ref))
            assert(bounds.object(policy.data)).environment = {}
            apply(policy)
            apply(batch)
            local ok, failure = pcall(function()
                local view = assert(tty.viewport({width = 160, height = 16}))
                local events = assert(process.events())
                local instance = "batch-ready-" .. assert(uuid.v7())
                local principal = assert(application.actor(WORKSPACE, instance,
                    assert(application.definition("bee.harness.app:app")), 1))
                local launched = assert(process.with_options({terminal = assert(view:grant())}):with_actor(principal):spawn_monitored(
                    "bee.tests.harness:window_ready_probe", "bee:workers", {version = 1,
                        broker_pid = process.pid(), workspace_pid = process.pid(), workspace_id = WORKSPACE,
                        instance_id = instance, view_id = instance, definition_id = "bee.harness.app:app",
                        execution_generation = 1, definition_revision = "1", registry_revision = "1",
                        launch_token = assert(uuid.v7()), resume_schema = recovery.SCHEMA, resume_state = "",
                        arguments = {DEFINITION, "Inspect stored memory"}}, process.pid()))
                local pid = tostring(launched)
                local deadline = time.after("30s")
                local completed = false
                while not completed do
                    local poll = time.after("100ms")
                    local selected = channel.select({events:case_receive(), deadline:case_receive(), poll:case_receive()})
                    local shown = table.concat(assert(view:snapshot()).rows, "\n")
                    if selected.channel == deadline then
                        process.cancel(pid, "batch launch test deadline")
                        error("batch did not reach completion: " .. shown)
                    elseif selected.channel == events then
                        test.is_false(selected.value.kind == process.event.EXIT and tostring(selected.value.from) == pid,
                            "batch launch exited before completion: " .. shown)
                    else
                        if shown:find("Claude login needed", 1, true) then
                            assert(view:send({type = "key", key = "", key_type = "enter", action = "press"}))
                        end
                        completed = shown:find("Batch completed", 1, true) ~= nil
                        if shown:find("Agent launch failed", 1, true) or shown:find("Batch failed:", 1, true) then
                            process.cancel(pid, "batch launch refused")
                            error("batch refused: " .. shown)
                        end
                    end
                end
                local db = assert(sql.get("bee:db"))
                local records = assert(db:query([[SELECT r.kind FROM bee_thread_records r
                    JOIN bee_thread_records a ON a.thread_id = r.thread_id AND a.action_id = r.action_id AND a.kind = 'action.admitted'
                    WHERE json_extract(a.record_json, '$.body.principal_id') = ? AND r.kind = 'attempt.started']], {principal:id()}))
                db:release()
                test.eq(#records, 1)
                assert(process.cancel(pid, "batch launch test complete"))
                view:close()
            end)
            apply(original)
            apply(original_policy)
            assert(ok, tostring(failure))
        end)
        for _, scenario in ipairs({{structured = false, owned = false}, {structured = true, owned = false}, {structured = false, owned = true}}) do
        local structured, owned = scenario.structured, scenario.owned
        test.it(owned and "records startup while the provider owns the surface" or
            "announces " .. (structured and "structured" or "direct") .. " launch readiness before opening the terminal", function()
            local ref = "bee.drivers.claude.descriptor:cli"
            local original = assert(registry.get(ref))
            local original_mode = assert(registry.get("bee.placement.native.env:placement_resource_mode"))
            local mode = assert(registry.get("bee.placement.native.env:placement_resource_mode"))
            mode.data = {mode = "granted"}
            apply(mode)
            local fixture = assert(registry.get(ref))
            local data = assert(bounds.object(fixture.data))
            -- This fixture tests the file advisory and its Enter continuation,
            -- independently from unobservable host environment/keychain login.
            data.login_evidence = {command = "claude", any_of = {{kind = "file_exists",
                paths = {".claude/.credentials.json"}, variable = "CLAUDE_CONFIG_DIR", directory = ".claude"}}}
            apply(fixture)
            local ok, failure = pcall(function()
            local view = assert(tty.viewport({width = 160, height = 16}))
            local grant = assert(view:grant())
            local events = assert(process.events())
            local ready = assert(process.listen("bee.app.ready", {message = true}))
            local opening = assert(process.listen("bee.test.window_opening", {message = true}))
            local checkpoint = assert(process.listen("bee.app.checkpoint", {message = true}))
            local self = tostring(process.pid())
            local instance_id = "window-ready-" .. uuid.v7()
            -- The broker runs an application under a principal bound to its workspace.
            local definition = assert(application.definition("bee.harness.app:app"))
            local principal = assert(application.actor(WORKSPACE, instance_id, definition, 1))
            local window, spawn_error = process.with_options({terminal = grant}):with_actor(principal):spawn_monitored(
                "bee.tests.harness:window_ready_probe", "bee:workers", {version = 1,
                    broker_pid = self, workspace_pid = self, workspace_id = WORKSPACE,
                    instance_id = instance_id, view_id = instance_id, definition_id = "bee.harness.app:app",
                    execution_generation = 1, definition_revision = "1", registry_revision = "1",
                    launch_token = uuid.v7(), resume_schema = recovery.SCHEMA, resume_state = "",
                    arguments = {structured and assert(json.encode({request_id = "structured-ready", definition_ref = DEFINITION, brief = ""})) or DEFINITION}}, self, owned)
            if not window then error("window spawn failed: " .. tostring(spawn_error)) end
            local pid = tostring(window)

            local announced = false
            local reached = false
            local login_notice = false
            local continued = false
            local deadline = time.after("60s")
            while not reached do
                local poll = time.after("100ms")
                local selected = channel.select({ready:case_receive(), opening:case_receive(),
                    events:case_receive(), deadline:case_receive(), poll:case_receive()})
                if not selected.ok or selected.channel == deadline then
                    local shown = view:snapshot()
                    error("the direct launch never reached the native open; the window shows:\n"
                        .. (shown and table.concat(shown.rows, "\n") or "nothing"))
                end
                if selected.channel == poll then
                    local shown = view:snapshot()
                    local rows = shown and table.concat(shown.rows, "\n") or ""
                    if rows:find("Claude login needed", 1, true) then
                        login_notice = true
                        assert(view:send({type = "key", key = "", key_type = "enter", action = "press"}))
                        continued = true
                    end
                elseif selected.channel == events then
                    local event = selected.value
                    assert(not (event.kind == process.event.EXIT and tostring(event.from) == pid),
                        "the window exited before its launch reached the native open")
                elseif selected.channel == ready then
                    if tostring(selected.value:from()) == pid then announced = true end
                elseif tostring(selected.value:from()) == pid then
                    reached = true
                end
            end
            local db = assert(sql.get("bee:db"))
            local decisions = assert(db:query([[SELECT d.assurance_json FROM bee_approval_decisions d
                JOIN bee_approval_requests r ON r.approval_id = d.approval_id
                WHERE json_extract(r.contract_json, '$.origin.instance_id') = ?
                AND json_extract(r.proposal_json, '$.payload.action') = 'login.acknowledge']], {instance_id}))
            test.eq(#decisions, 1)
            local assurance = assert(bounds.object(json.decode(tostring(decisions[1].assurance_json))))
            test.eq(assurance.gesture, "enter")
            test.eq(assurance.presentation, "inline")
            test.eq(#assert(db:query([[SELECT g.grant_id FROM bee_approval_grants g
                JOIN bee_approval_requests r ON r.approval_id = g.approval_id
                WHERE json_extract(r.contract_json, '$.origin.instance_id') = ?]], {instance_id})), 0)
            db:release()
            local starting = assert(view:snapshot())
            test.is_true(table.concat(starting.rows, "\n"):find("Starting process", 1, true) ~= nil,
                "the launch surface does not identify the blocked native-open phase")
            -- Both messages come from the window process, so their order is
            -- the order in which the window sent them.
            test.is_true(announced, "the window held readiness behind launch work that was still running")
            test.is_true(login_notice, "the direct launch did not show its Claude login notice")
            test.is_true(continued, "the Claude login notice did not continue to native open on Enter")

            assert(process.send(pid, "bee.test.window_release", {version = 1}))
            if owned then
                local recorded = false
                local completion_deadline = time.after("30s")
                while not recorded do
                    local selected = channel.select({checkpoint:case_receive(), events:case_receive(), completion_deadline:case_receive()})
                    assert(selected.ok and selected.channel ~= completion_deadline, "startup did not record its supervised process start")
                    if selected.channel == events then
                        local event = selected.value
                        assert(not (event.kind == process.event.EXIT and tostring(event.from) == pid),
                            "the provider surface owner exited: " .. tostring(event.result and event.result.error))
                    elseif tostring(selected.value:from()) == pid then recorded = true end
                end
                test.contains(table.concat(assert(view:snapshot()).rows, "\n"), "Provider owns the terminal")
            end
            assert(process.cancel(pid, "readiness test complete"))
            local exited = false
            local stop_deadline = time.after("30s")
            while not exited do
                local selected = channel.select({events:case_receive(), stop_deadline:case_receive()})
                assert(selected.ok and selected.channel == events, "the window did not exit after cancellation")
                local event = selected.value
                exited = event.kind == process.event.EXIT and tostring(event.from) == pid
            end
            process.unlisten(ready)
            process.unlisten(opening)
            process.unlisten(checkpoint)
            view:close()
            end)
            apply(original)
            apply(original_mode)
            if not ok then error(tostring(failure)) end
        end)
        end
    end)
end
return test.run_cases(define_tests)
