-- MIT. Native placement startup regressions.
local test = require("test")
local bounds = require("bounds")
local principals = require("principals")
local funcs = require("funcs")
local sql = require("sql")
local security = require("security")
local process = require("process")
local runner_fixture = require("runner_fixture")
local channel = require("channel")
local time = require("time")
local registry = require("registry")
local exec = require("exec")
local fs = require("fs")
local service = require("service")
local identity = require("identity")
local configuration = require("configuration")
local grok_configuration = require("grok_configuration")
local grok_launch = require("grok_launch")
local claude_launch = require("claude_launch")
local codex_launch = require("codex_launch")
local agy_launch = require("agy_launch")
local muse_launch = require("muse_launch")
local opencode_launch = require("opencode_launch")
local configuration_protocol = require("configuration_protocol")
local preferences = require("preferences")
local hash = require("hash")
local json = require("json")
local store = require("store")
local materialization = require("materialization")
local resources = require("resources")
local request_codec = require("request_codec")
local protocol = require("protocol")
local output_buffer = require("output_buffer")
local homes = require("homes")
local quote = require("quote")
local types = require("types")
local placement_decode = require("placement_decode")
local executable_stream = require("executable_stream")
local exits = require("exits")
local native_fixture = require("native_fixture")
type PreparedConfiguration = {environment: {[string]: string}, working_directory: string, arguments: {string}}

local function startup_tests()
    test.describe("Supervised placement startup", function()
        test.it("returns a monitored starting attempt without waiting for acknowledgement", function()
            local request = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            local pending = assert(process.listen("bee.test.startup.pending", {message = true}))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "attach", {attempt_id = prepared.attempt_id, recipient = process.pid(), generation = 1}))
            local raw, call_error = native_fixture.caller(native_fixture.OWNER):call("bee.placement.native:fixture_start_unacknowledged", {attempt_id = prepared.attempt_id})
            assert(not call_error, tostring(call_error))
            local started = native_fixture.attempt_of(principals.reply(raw))
            test.eq(started.execution_state, "starting")
            local runner = assert(started.runner)
            assert(process.monitor(runner))
            local events = assert(process.events())
            exits.paused(runner, "startup.pending", {}, function(poll: boolean): unknown
                local selected
                if poll then
                    selected = channel.select({pending:case_receive(), default = true})
                    if selected.default then return nil end
                else selected = channel.select({pending:case_receive(), events:case_receive()}) end
                assert(selected.ok, "startup barrier observation channel closed")
                if selected.channel == events then return selected.value end
                local message = selected.value
                local data = assert(bounds.object(message:payload():data()), "invalid startup barrier")
                return {kind = "pause", from = tostring(message:from()), step = data.attempt_id == prepared.attempt_id and "startup.pending" or "other"}
            end)
            process.unlisten(pending)
            local states = assert(process.listen(protocol.TOPIC_STARTED, {message = true}))
            assert(process.send(runner, "bee.test.startup.advance", {}))
            while true do
                local status = assert(placement_decode.status(native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id}))))
                if status.attempt.execution_state == "running" then break end
                assert(not status.attempt.start_failure, tostring(status.attempt.start_failure))
                assert((states:receive()), "startup publication channel closed")
            end
            process.unlisten(states)
            assert(process.terminate(runner))
            local recorded = native_fixture.kinds(prepared.attempt_id)
            test.is_true(native_fixture.has(recorded, "runner.start_accepted"))
            test.is_false(native_fixture.has(recorded, "runner.start_deadline"))
            test.is_true(native_fixture.has(recorded, "child.started"))
        end)
        for _, command in ipairs({"acknowledge", "refuse", "crash"}) do
            test.it("retains monitored startup until runner " .. command, function()
                local mode = command == "crash" and "exit" or command
                local request = native_fixture.launch({"sh", mode}, "direct_process")
                local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
                local pending = assert(process.listen("bee.test.startup.pending", {message = true}))
                native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "attach", {attempt_id = prepared.attempt_id, recipient = process.pid(), generation = 1}))
                local future = assert(native_fixture.caller(native_fixture.OWNER):async("bee.placement.native:fixture_start_unacknowledged", {attempt_id = prepared.attempt_id}))
                local accepted = native_fixture.attempt_of(principals.reply(native_fixture.await(future)))
                test.eq(accepted.execution_state, "starting")
                local message = assert((pending:receive()), "startup barrier observation channel closed")
                process.unlisten(pending)
                local runner = tostring(message:from())
                local events = assert(process.events())
                assert(process.monitor(runner))
                local data = assert(bounds.object(message:payload():data()))
                local states = assert(process.listen(protocol.TOPIC_STARTED, {message = true}))
                local runner_ended = false
                local ok, failure = pcall(function()
                    test.eq(data.attempt_id, prepared.attempt_id)
                    test.eq(accepted.runner, runner)
                    assert(type(data.supervisor) == "string" and type(data.reply_topic) == "string")
                    local current = native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id})).attempt
                    test.eq(current.execution_state, "starting")
                    test.eq(current.runner, runner)
                    test.is_false(native_fixture.has(native_fixture.kinds(prepared.attempt_id), "child.started"))
                    assert(process.send(data.supervisor, data.reply_topic, {started = true}))
                    assert(process.send(runner, "bee.test.startup.advance", {}))
                    local expected = command == "acknowledge" and "running" or "start_failed"
                    while true do
                        local observed = native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id})).attempt
                        local acknowledged = command == "crash" or native_fixture.has(native_fixture.kinds(prepared.attempt_id), "runner.ack_received")
                        if observed.execution_state == expected and acknowledged then break end
                        local selected = channel.select({states:case_receive(), events:case_receive()})
                        assert(selected.ok, "startup state observation channel closed")
                        if selected.channel == events then
                            local event = selected.value
                            assert(event.kind ~= process.event.CANCEL, "startup observation cancelled")
                            if event.kind == process.event.EXIT and tostring(event.from) == runner then runner_ended = true end
                        end
                    end
                    local acknowledgements = 0
                    for _, kind in ipairs(native_fixture.kinds(prepared.attempt_id)) do
                        if kind == "runner.ack_received" then acknowledgements = acknowledgements + 1 end
                    end
                    test.eq(acknowledgements, command == "crash" and 0 or 1)
                    local observed = native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id})).attempt
                    if command == "acknowledge" then
                        test.eq(observed.attempt_id, prepared.attempt_id)
                        test.is_nil(observed.start_failure)
                    elseif command == "refuse" then
                        test.eq(observed.start_failure, "fixture daemon refused containers/create")
                    else
                        local detail = tostring(observed.start_failure)
                        test.is_true(detail:find("runner exited before acknowledging startup", 1, true) ~= nil)
                        test.is_true(detail:find("fixture runner crashed before acknowledgement", 1, true) ~= nil)
                    end
                end)
                if command == "acknowledge" or not ok then process.terminate(runner) end
                while not runner_ended do
                    local ended = assert((events:receive()), "startup supervision channel closed")
                    assert(ended.kind ~= process.event.CANCEL, "startup observation cancelled")
                    if ended.kind == process.event.EXIT and tostring(ended.from) == runner then runner_ended = true end
                end
                process.unlisten(states)
                process.unmonitor(runner)
                if not ok then error(tostring(failure)) end
            end)
        end
    end)
end


return {startup = native_fixture.suite(startup_tests)}
