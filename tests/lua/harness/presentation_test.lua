-- MIT. Retained presentation enters the fixed host scope through a trusted function boundary.
local test = require("test")
local bounds = require("bounds")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local process = require("process")
local tty = require("tty")
local time = require("time")
local channel = require("channel")
local function apply(entry: {[string]: unknown})
    local changes = assert(registry.snapshot()):changes()
    changes:update(entry)
    assert(changes:apply())
end
local function define_tests()
    test.describe("Presentation execution boundary", function()
        test.it("preserves the caller while leaving application spawn denials at the facade", function()
            local original = assert(registry.get("bee.harness.service:open"))
            local probe = assert(registry.get("bee.harness.catalog:presentation_scope_probe"))
            probe.id = "bee.harness.service:open"
            apply(probe)
            local ok, failure = pcall(function()
                local workspace = string.rep("a", 32)
                local actor = assert(security.new_actor("presentation-caller", {workspace_id = workspace}))
                local scope = security.new_scope({assert(security.policy("bee.harness.security:carrier_policy")),
                    assert(security.policy("bee.security:scope_managing_app_boundary")),
                    assert(security.policy("bee.harness.security:profile_context_boundary"))})
                test.eq(scope:evaluate(actor, "process.context", "context"), "deny")
                local raw, err = funcs.new():with_actor(actor):with_scope(scope):call("bee.harness.launch:present", {})
                if err then error(tostring(err)) end
                local reply = raw
                test.is_true(reply.ok)
                test.eq(reply.value.owner, "presentation-caller")
                test.eq(reply.value.workspace, workspace)
                test.is_true(reply.value.terminal_spawn)
            end)
            apply(original)
            if not ok then error(tostring(failure)) end
        end)
        test.it("waits for the first frame and reattaches after the viewer closes", function()
            local original = assert(registry.get("bee.sessions.binding:get"))
            local fixture = assert(registry.get("bee.harness.catalog:presentation_view_get"))
            fixture.id = "bee.sessions.binding:get"
            apply(fixture)
            local requests = assert(process.listen("bee.session.window.request", {message = true}))
            assert(process.registry.register("bee.session.window/fixture-session"))
            local content = assert(tty.viewport({width = 80, height = 24}))
            local producer = assert(process.with_options({terminal = assert(content:grant())}):spawn_monitored(
                "bee.harness.catalog:presentation_producer", "bee:workers", tostring(process.pid())))
            local ok, failure = pcall(function()
                local ready = assert(process.listen("bee.test.viewer_ready", {message = true}))
                local finished = assert(process.listen("bee.test.viewer_finished", {message = true}))
                local resized = assert(process.listen("bee.test.viewer_resized", {message = true}))
                local scope = security.new_scope({assert(security.policy("bee.harness.security:carrier_policy")),
                    assert(security.policy("bee.security:scope_managing_app_boundary")),
                    assert(security.policy("bee.harness.security:profile_context_boundary")),
                    assert(security.policy("bee.harness.security:presentation_viewer_policy"))})
                for index = 1, 2 do
                    local output = assert(tty.viewport({width = 120, height = 20}))
                    local self = tostring(process.pid())
                    local identity = "presentation-view-" .. tostring(index)
                    local viewer = assert(process.with_options({terminal = assert(output:grant())}):with_scope(scope):with_actor(assert(security.new_actor("viewer-person", {workspace_id = string.rep("a", 32)}))):spawn_monitored(
                        "bee.harness.catalog:presentation_viewer", "bee:workers", {version = 1,
                            broker_pid = self, workspace_pid = self, workspace_id = string.rep("a", 32),
                            instance_id = identity, view_id = identity, definition_id = "bee.harness.app:app",
                            execution_generation = 1, definition_revision = "1", registry_revision = "1",
                            launch_token = identity, resume_schema = "bee.agent.window@1", resume_state = "", arguments = {}}, self))
                    local announced = ready:receive()
                    test.not_nil(announced)
                    coroutine.spawn(function()
                        while true do
                            local message = requests:receive()
                            if not message then return end
                            local body = assert(bounds.object(message:payload():data()))
                            local sender = tostring(message:from())
                            assert(sender == tostring(viewer), "mount RPC sender is not the viewer process")
                            if sender == tostring(viewer) then
                                local mount = body.op == "attach" and assert(content:mount(sender, {observe = true, input = true, resize = true})) or nil
                                process.send(sender, "bee.session.window.reply", {ok = true, caller_token = body.caller_token, value = {mount = mount}})
                                if body.op == "detach" then return end
                            end
                        end
                    end)
                    assert(process.send(viewer, "bee.test.viewer_release", {}))
                    if index == 1 then
                        local event = channel.select({resized:case_receive(), finished:case_receive(), time.after("10s"):case_receive()})
                        assert(event.ok and event.channel == resized, "viewer did not attach: " .. tostring(event.channel == finished and event.value:payload():data().error or "no resize"))
                        assert(process.send(producer, "bee.test.publish", {}))
                    end
                    local deadline = time.after("10s")
                    while true do
                        local snapshot = output:snapshot()
                        if snapshot and table.concat(snapshot.rows, "\n"):find("retained prior terminal content", 1, true) then break end
                        local poll = time.after("20ms")
                        local event = channel.select({finished:case_receive(), deadline:case_receive(), poll:case_receive()})
                        assert(event.ok and event.channel == poll, "viewer closed or failed before publishing the retained frame")
                    end
                    assert(output:send({type = "close"}))
                    local done = finished:receive()
                    test.not_nil(done)
                    test.is_true(content:snapshot() ~= nil)
                    output:close()
                end
                process.unlisten(ready); process.unlisten(finished); process.unlisten(resized)
            end)
            process.cancel(producer, "presentation fixture complete")
            content:close()
            process.registry.unregister("bee.session.window/fixture-session", process.registry.LOCAL)
            process.unlisten(requests)
            apply(original)
            if not ok then error(tostring(failure)) end
        end)
    end)
end
return test.run_cases(define_tests)
