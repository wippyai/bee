-- MIT. A direct managed window launch is ready for its broker as soon as its
-- surface can say what it is doing. Resolution, admission, preparation and the
-- native open are durable work of unbounded length; the broker's startup
-- deadline bounds surface readiness only, so readiness never waits for them.
local test = require("test")
local bounds = require("bounds")
local registry = require("registry")
local principals = require("principals")
local process = require("process")
local channel = require("channel")
local time = require("time")
local tty = require("tty")
local uuid = require("uuid")
local json = require("json")
local recovery = require("recovery")

local WORKSPACE = string.rep("c", 32)
local DEFINITION = "bee.harness.catalog:window_ready_definition"

local function apply(entry: {[string]: unknown})
    local changes = assert(registry.snapshot()):changes()
    changes:update(entry)
    assert(changes:apply())
end

local function define_tests()
    test.describe("Managed window readiness", function()
        for _, structured in ipairs({false, true}) do
        test.it("announces " .. (structured and "structured" or "direct") .. " launch readiness before opening the terminal", function()
            local ref = "bee.driver.claude.descriptor:cli"
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
            local self = tostring(process.pid())
            local instance_id = "window-ready-" .. uuid.v7()
            -- The broker runs an application under a principal bound to its workspace.
            local principal = principals.actor("bee.application:" .. WORKSPACE .. ":" .. instance_id, WORKSPACE)
            local window, spawn_error = process.with_options({terminal = grant}):with_actor(principal):spawn_monitored(
                "bee.harness.catalog:window_ready_probe", "bee:workers", {version = 1,
                    broker_pid = self, workspace_pid = self, workspace_id = WORKSPACE,
                    instance_id = instance_id, view_id = instance_id, definition_id = "bee.harness.app:app",
                    execution_generation = 1, definition_revision = "1", registry_revision = "1",
                    launch_token = uuid.v7(), resume_schema = recovery.SCHEMA, resume_state = "",
                    arguments = {structured and assert(json.encode({request_id = "structured-ready", definition_ref = DEFINITION, brief = ""})) or DEFINITION}}, self)
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
            local starting = assert(view:snapshot())
            test.is_true(table.concat(starting.rows, "\n"):find("Starting process", 1, true) ~= nil,
                "the launch surface does not identify the blocked native-open phase")
            -- Both messages come from the window process, so their order is
            -- the order in which the window sent them.
            test.is_true(announced, "the window held readiness behind launch work that was still running")
            test.is_true(login_notice, "the direct launch did not show its Claude login notice")
            test.is_true(continued, "the Claude login notice did not continue to native open on Enter")

            assert(process.send(pid, "bee.test.window_release", {version = 1}))
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
