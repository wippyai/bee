-- MIT. A session restored from a kept desktop window and from Agents has one owner.
local test = require("test")
local bounds = require("bounds")
local security = require("security")
local registry = require("registry")
local process = require("process")
local tty = require("tty")
local time = require("time")
local channel = require("channel")
local recovery = require("recovery")
local probe = require("probe")
local function apply(entry: {[string]: unknown})
    local changes = assert(registry.snapshot()):changes()
    changes:update(entry)
    assert(changes:apply())
end
local function replace(target: string, fixture: string): {[string]: unknown}
    local original = assert(registry.get(target))
    local replacement = assert(registry.get(fixture))
    replacement.id = target
    apply(replacement)
    return original
end
local function define_tests()
    test.describe("Session restore ownership", function()
        test.it("a kept desktop window attaches to the session owner that Agents started instead of restoring again", function()
            -- The test composition selects the fake Sessions owner as the
            -- contract's binding; both list targets answer with the session.
            local originals = {replace("bee.threads.sessions.binding:list", "bee.tests.harness:single_owner_list"),
                replace("bee.tests.threads.sessions:fake_list", "bee.tests.harness:single_owner_list"),
                replace("bee.threads.sessions.binding:get", "bee.tests.harness:presentation_view_get"),
                replace("bee.threads.sessions.binding:attach", "bee.tests.harness:single_owner_attach")}
            local requests = assert(process.listen("bee.session.window.request", {message = true}))
            local restorers = assert(process.listen("bee.test.second_restorer", {message = true}))
            assert(process.registry.register(probe.OBSERVER))
            -- Agents restored the session first: its owner holds the session name.
            assert(process.registry.register("bee.session.window/" .. probe.SESSION))
            local content = assert(tty.viewport({width = 80, height = 24}))
            local output = assert(tty.viewport({width = 120, height = 20}))
            local events = assert(process.events())
            local window: string? = nil
            local ok, failure = pcall(function()
                local saved = assert(recovery.encode({definition_ref = "bee.driver.claude.profiles:default_window", plan_digest = string.rep("a", 64),
                    origin_request_id = "single-owner-origin", previous_attempt_id = "attempt:single-owner-origin", thread_id = probe.THREAD}))
                local scope = security.new_scope({assert(security.policy("bee.harness.security:carrier_policy")),
                    assert(security.policy("bee.node.security:application_scope_boundary")),
                    assert(security.policy("bee.harness.security:profile_context_boundary")),
                    assert(security.policy("bee.harness.security:presentation_viewer_policy")),
                    assert(security.policy("bee.harness.security:harness_setup_policy")),
                    assert(security.policy("bee.tests.harness:single_owner_contract_policy"))})
                local self = tostring(process.pid())
                local spawned = assert(process.with_options({terminal = assert(output:grant())}):with_scope(scope)
                    :with_actor(assert(security.new_actor("bee.application:" .. probe.WORKSPACE .. ":kept-window", {workspace_id = probe.WORKSPACE})))
                    :spawn_monitored("bee.harness.app:execution", "bee:workers", {version = 1,
                        broker_pid = self, workspace_pid = self, workspace_id = probe.WORKSPACE,
                        instance_id = "kept-window", view_id = "kept-window", definition_id = "bee.harness.app:app",
                        execution_generation = 1, definition_revision = "1", registry_revision = "1",
                        launch_token = "kept-window", resume_schema = recovery.SCHEMA, resume_state = saved,
                        arguments = {"bee.driver.claude.profiles:default_window"}}))
                window = tostring(spawned)
                local attached = false
                local deadline = time.after("30s")
                while not attached do
                    local event = channel.select({requests:case_receive(), restorers:case_receive(), events:case_receive(), deadline:case_receive()})
                    if not event.ok or event.channel == deadline then
                        local shown = output:snapshot()
                        error("the kept window neither attached to the owner nor restored; it shows:\n" .. (shown and table.concat(shown.rows, "\n") or "nothing"))
                    end
                    assert(event.channel ~= restorers, "the kept window admitted a second continuation of the session")
                    if event.channel == events then
                        assert(not (event.value.kind == process.event.EXIT and tostring(event.value.from) == tostring(window)),
                            "the kept window exited before attaching to the owner")
                    else
                        local body = assert(bounds.object(event.value:payload():data()))
                        local sender = tostring(event.value:from())
                        local mount = body.op == "attach" and assert(content:mount(sender, {observe = true, input = true, resize = true})) or nil
                        process.send(sender, "bee.session.window.reply", {ok = true, caller_token = body.caller_token, value = {mount = mount}})
                        attached = body.op == "attach"
                    end
                end
                assert(output:send({type = "close"}))
                local closed = time.after("30s")
                while true do
                    local event = channel.select({events:case_receive(), requests:case_receive(), restorers:case_receive(), closed:case_receive()})
                    assert(event.ok and event.channel ~= closed, "the kept window did not close")
                    assert(event.channel ~= restorers, "the kept window admitted a second continuation of the session")
                    if event.channel == requests then
                        local body = assert(bounds.object(event.value:payload():data()))
                        process.send(tostring(event.value:from()), "bee.session.window.reply", {ok = true, caller_token = body.caller_token, value = {}})
                    elseif event.value.kind == process.event.EXIT and tostring(event.value.from) == tostring(window) then
                        break
                    end
                end
            end)
            if not ok and window then
                process.cancel(window, "ownership fixture failed")
                local stopped = time.after("10s")
                while true do
                    local event = channel.select({events:case_receive(), stopped:case_receive()})
                    if not event.ok or event.channel == stopped then break end
                    if event.value.kind == process.event.EXIT and tostring(event.value.from) == window then break end
                end
            end
            output:close()
            content:close()
            process.registry.unregister("bee.session.window/" .. probe.SESSION, process.registry.LOCAL)
            process.registry.unregister(probe.OBSERVER, process.registry.LOCAL)
            process.unlisten(requests)
            process.unlisten(restorers)
            for _, original in ipairs(originals) do apply(original) end
            if not ok then error(tostring(failure)) end
        end)
    end)
end
return test.run_cases(define_tests)
