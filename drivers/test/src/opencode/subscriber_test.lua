-- SPDX-License-Identifier: MIT
local test = require("test")
local exec = require("exec")
local process = require("process")
local channel = require("channel")
local time = require("time")
local http = require("http_client")
local json = require("json")
local bounds = require("bounds")
local quote = require("quote")
-- The recorded OpenCode server captures, relative to the harness root.
local fixtures = "fixtures/drivers/opencode/"
local function define_tests()
    test.describe("OpenCode HTTP subscriber", function()
        test.it("records the failed startup operation without exposing the HTTP payload", function()
            local executor = assert(exec.get("bee.drivers.tests.opencode:fixture_server"))
            local server = assert(executor:exec(quote.line({"/usr/bin/python3", fixtures .. "http-server.py", fixtures .. "http-events-1", "/session/status"}), {process_group = true}))
            local stdout = server:stdout_stream()
            assert(server:start())
            local endpoint = assert(stdout:read(256)):match("http://127%.0%.0%.1:%d+")
            assert(endpoint)
            local topic = "bee.fixture.opencode.failure"
            local replies = assert(process.listen(topic, {message = true}))
            local child = assert(process.spawn("bee.drivers.opencode.observer:subscriber", "bee.drivers.tests.host:processes", {
                endpoint = endpoint, hook_endpoint = endpoint .. "/hook/action-1", hook_token = "fixture-hook",
                hooks = {}, argv = {}, working_directory = fixtures, owner = process.pid(), topic = topic,
            }))
            local ok, failure = pcall(function()
                local selected = channel.select({replies:case_receive(), time.after("30s"):case_receive()})
                assert(selected.ok and selected.channel == replies, "subscriber response deadline")
                local reply = assert(bounds.object(selected.value:payload():data()))
                test.eq(reply.kind, "failed")
                test.eq(reply.detail, "OpenCode observer stopped during GET /session/status (HTTP 503)")
            end)
            process.cancel(child, "subscriber fixture cleanup")
            process.unlisten(replies)
            server:close()
            stdout:close()
            executor:release()
            if not ok then error(tostring(failure)) end
        end)
        test.it("subscribes before the prompt, delivers captured hooks and permissions, and stops with its window", function()
            for _, case in ipairs({{auto = false, brief = "Fixture peer request"}, {auto = true, brief = "Fixture peer request"}, {auto = false, brief = "--auto"}}) do
            local auto = case.auto
            local executor = assert(exec.get("bee.drivers.tests.opencode:fixture_server"))
            local server = assert(executor:exec(quote.line({"/usr/bin/python3", fixtures .. "http-server.py", fixtures .. "http-events-1"}), {process_group = true}))
            local stdout = server:stdout_stream()
            assert(server:start())
            local endpoint = assert(stdout:read(256)):match("http://127%.0%.0%.1:%d+")
            assert(endpoint)
            local topic = "bee.fixture.opencode.subscriber"
            local replies = assert(process.listen(topic, {message = true}))
            local child = assert(process.spawn("bee.drivers.opencode.observer:subscriber", "bee.drivers.tests.host:processes", {
                endpoint = endpoint, hook_endpoint = endpoint .. "/hook/action-1", hook_token = "fixture-hook",
                hooks = {"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "SessionEnd"},
                argv = auto and {"--auto", "--prompt", case.brief} or {"--prompt", case.brief}, working_directory = fixtures, owner = process.pid(), topic = topic,
            }))
            local function receive(): {[string]: unknown}
                local selected = channel.select({replies:case_receive(), time.after("30s"):case_receive()})
                assert(selected.ok and selected.channel == replies, "subscriber response deadline")
                return assert(bounds.object(selected.value:payload():data()))
            end
            local ok, failure = pcall(function()
                local ready = receive()
                assert(ready.kind == "ready", tostring(ready.detail))
                test.eq(ready.kind, "ready")
                local arguments = assert(bounds.array(ready.arguments, 8))
                test.eq(arguments[1], "attach")
                test.eq(arguments[2], endpoint)
                local before = assert(http.get(endpoint .. "/state"))
                test.eq(assert(bounds.object(json.decode(assert(before.body)))).started, false)
                process.send(child, topic .. ".control", {command = "release"})
                local result = assert(http.get(endpoint .. "/captured", {timeout = "25s"}))
                local captured = assert(bounds.object(json.decode(assert(result.body))))
                test.eq(captured.permission_replied, true)
                local stops = 0
                local starts = 0
                local tool_events: {string} = {}
                local permission_hooks = 0
                for _, raw in ipairs(assert(bounds.array(captured.hooks, 64))) do
                    local row = assert(bounds.object(raw))
                    if row.hook_event_name == "PermissionRequest" then permission_hooks = permission_hooks + 1 end
                    if row.hook_event_name == "SessionStart" then starts = starts + 1 end
                    if row.hook_event_name == "PreToolUse" or row.hook_event_name == "PostToolUse" then tool_events[#tool_events + 1] = tostring(row.hook_event_name) end
                    if row.hook_event_name == "Stop" then
                        stops = stops + 1
                        test.eq(row.last_assistant_message, "Acknowledged fixture peer request")
                    end
                end
                test.eq(permission_hooks, auto and 0 or 1)
                test.eq(starts, 1)
                test.eq(stops, 1)
                test.eq(table.concat(tool_events, ","), "PreToolUse,PostToolUse")
                process.send(child, topic .. ".control", {command = "stop"})
                test.eq(receive().kind, "stopped")
            end)
            process.cancel(child, "subscriber fixture cleanup")
            process.unlisten(replies)
            server:close()
            stdout:close()
            executor:release()
            if not ok then error(tostring(failure)) end
            end
        end)
    end)
end
return test.run_cases(define_tests)
