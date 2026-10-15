-- SPDX-License-Identifier: MIT
local test = require("test")
local registry = require("registry")
local process = require("process")
local channel = require("channel")
local time = require("time")
local security = require("security")
local viewer = require("viewer")
local uuid = require("uuid")
local function apply(entry: {[string]: unknown})
    local changes = assert(registry.snapshot()):changes()
    changes:update(entry)
    assert(changes:apply())
end
local function cases()
    test.describe("Supervised retained presentation", function()
        test.it("declares its host, boot dependency and bounded restart policy", function()
            local service = assert(registry.get("bee.harness.service:presentation_service"))
            test.eq(service.kind, "process.service")
            test.eq(service.data.host, "bee:workers")
            test.eq(service.data.lifecycle.requires[1], "wippy.bootloader:bootloader.service")
            test.eq(service.data.lifecycle.restart.max_attempts, 10)
        end)
        test.it("refuses a launch carrying only a viewer registration", function()
            local supervisor = assert(process.registry.lookup("bee.harness.presentation"))
            local token = "bee.session.viewer/" .. assert(uuid.v7())
            local replies = assert(process.listen("bee.session.window.reply", {message = true}))
            assert(process.registry.register(token))
            assert(process.send(supervisor, "bee.session.window.launch", {caller_token = token}))
            local event = channel.select({replies:case_receive(), time.after("5s"):case_receive()})
            process.registry.unregister(token)
            process.unlisten(replies)
            assert(event.ok and event.channel == replies, "presentation service did not refuse the launch")
            local result = event.value:payload():data()
            test.is_false(result.ok)
            test.eq(result.error.message, "presentation launch capability is missing")
            local scope = security.new_scope({assert(security.policy("bee.harness.security:presentation_viewer_policy"))})
            test.neq(scope:evaluate(assert(security.actor()), "process.registry.register", "bee.session.launch/" .. assert(uuid.v7())), "allow")
        end)
        test.it("keeps the window principal and joins children when the service crashes", function()
            local original = assert(registry.get("bee.harness.service:presentation_owner"))
            local fixture = assert(registry.get("bee.tests.harness.service:owner_probe"))
            fixture.id = original.id
            apply(fixture)
            local lifecycle = assert(process.events())
            local child: string? = nil
            local ok, problem = pcall(function()
                local supervisor = tostring(assert(process.registry.lookup("bee.harness.presentation")))
                local actor = assert(security.new_actor("presentation-fixture", {workspace_id = "fixture-workspace"}))
                local function open(): {[string]: unknown}
                    return viewer.rpc(nil, {op = "resume"}, {session = "fixture-session"}, "bee.session.window/fixture-session", "fixture-key",
                        {actor = actor, workspace = "fixture-workspace", trait_ceiling = {"fixture-trait"}})
                end
                local opened = open()
                test.is_true(opened.ok, tostring(opened.error and opened.error.message))
                child = opened.value.pid
                test.eq(opened.value.actor, "presentation-fixture")
                test.eq(opened.value.workspace, "fixture-workspace")
                test.eq(opened.value.ceiling[1], "fixture-trait")
                test.eq(opened.value.operation_key, "fixture-key")
                test.eq(open().value.pid, child)
                assert(process.monitor(assert(child)))
                assert(process.terminate(supervisor))
                local deadline = time.after("10s")
                while true do
                    local event = channel.select({lifecycle:case_receive(), deadline:case_receive()})
                    assert(event.ok and event.channel == lifecycle, "presentation child survives its service")
                    if event.value.kind == process.event.EXIT and tostring(event.value.from) == child then break end
                end
                child = nil
                while true do
                    local replacement = process.registry.lookup("bee.harness.presentation")
                    if replacement and tostring(replacement) ~= supervisor then break end
                    local tick = time.after("10ms")
                    local event = channel.select({tick:case_receive(), deadline:case_receive()})
                    assert(event.channel == tick, "presentation service did not restart")
                end
                local resumed = open()
                test.is_true(resumed.ok, tostring(resumed.error and resumed.error.message))
                child = resumed.value.pid
                test.neq(child, opened.value.pid)
            end)
            if child then
                assert(process.monitor(child))
                process.cancel(child, "supervision fixture complete")
                local deadline = time.after("5s")
                while true do
                    local event = channel.select({lifecycle:case_receive(), deadline:case_receive()})
                    assert(event.ok and event.channel == lifecycle, "presentation fixture did not stop")
                    if event.value.kind == process.event.EXIT and tostring(event.value.from) == child then break end
                end
            end
            apply(original)
            if not ok then error(tostring(problem)) end
        end)
    end)
end
return test.run_cases(cases)
