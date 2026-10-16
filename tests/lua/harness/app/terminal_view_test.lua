-- MIT. A session's viewer shows the review its window owner sends and no other.
local test = require("test")
local bounds = require("bounds")
local security = require("security")
local registry = require("registry")
local process = require("process")
local tty = require("tty")
local time = require("time")
local channel = require("channel")
local viewer_review = require("viewer")
local function apply(entry: {[string]: unknown})
    local changes = assert(registry.snapshot()):changes()
    changes:update(entry)
    assert(changes:apply())
end
local function received(inbox: channel.Channel<process.Message>): {[string]: unknown}?
    local event = channel.select({inbox:case_receive(), time.after("10s"):case_receive()})
    if event.channel ~= inbox then return nil end
    return bounds.object(event.value:payload():data())
end
local function define_tests()
    test.describe("Session review", function()
        test.it("follows the requests bound to the session's thread or asked by its window", function()
            local requested = {kind = "approval.requested", data = {title = "Allow Bee to use config.toml?",
                request = {approval_id = "config", requester_id = "window-principal", state = "pending"}}}
            local shown, changed = viewer_review.review(nil, requested, "thread-1", "window-principal")
            test.is_true(changed)
            test.eq(assert(shown).approval_id, "config")
            test.eq(assert(shown).title, "Allow Bee to use config.toml?")
            local other = {kind = "approval.requested", data = {title = "Other", request = {approval_id = "other",
                requester_id = "someone", thread_id = "thread-2", state = "pending"}}}
            local kept, other_changed = viewer_review.review(shown, other, "thread-1", "window-principal")
            test.is_false(other_changed)
            test.eq(assert(kept).approval_id, "config")
            local bound = {kind = "approval.requested", data = {title = "Let this agent session use Hub and Library?",
                request = {approval_id = "access", requester_id = "bs:session", thread_id = "thread-1", state = "pending"}}}
            local access = assert((viewer_review.review(kept, bound, "thread-1", "window-principal")))
            test.eq(access.approval_id, "access")
            local unrelated_settled = {kind = "approval.changed", data = {request = {approval_id = "config", state = "decided"}}}
            local still, still_changed = viewer_review.review(access, unrelated_settled, "thread-1", "window-principal")
            test.is_false(still_changed)
            test.eq(assert(still).approval_id, "access")
            local settled = {kind = "approval.changed", data = {request = {approval_id = "access", thread_id = "thread-1", state = "decided"}}}
            local cleared, cleared_changed = viewer_review.review(still, settled, "thread-1", "window-principal")
            test.is_true(cleared_changed)
            test.is_nil(cleared)
        end)
    end)
    test.describe("Presentation execution boundary", function()
        test.it("shows the review its window owner sends, ignores any other sender and clears it on close", function()
            local original = assert(registry.get("bee.threads.sessions.binding:get"))
            local fixture = assert(registry.get("bee.tests.harness:presentation_view_get"))
            fixture.id = "bee.threads.sessions.binding:get"
            apply(fixture)
            local reviews = assert(process.listen("bee.app.review", {message = true}))
            local requests = assert(process.listen("bee.session.window.request", {message = true}))
            assert(process.registry.register("bee.session.window/fixture-session"))
            local content = assert(tty.viewport({width = 80, height = 24}))
            local producer = assert(process.with_options({terminal = assert(content:grant())}):spawn_monitored(
                "bee.tests.harness:presentation_producer", "bee:workers", tostring(process.pid())))
            local ok, failure = pcall(function()
                local ready = assert(process.listen("bee.test.viewer_ready", {message = true}))
                local finished = assert(process.listen("bee.test.viewer_finished", {message = true}))
                local resized = assert(process.listen("bee.test.viewer_resized", {message = true}))
                local spoofed = assert(process.listen("bee.test.spoof_sent", {message = true}))
                local scope = security.new_scope({assert(security.policy("bee.harness.security:carrier_policy")),
                    assert(security.policy("bee.node.security:application_scope_boundary")),
                    assert(security.policy("bee.harness.security:profile_context_boundary")),
                    assert(security.policy("bee.harness.security:presentation_viewer_policy"))})
                local output = assert(tty.viewport({width = 120, height = 20}))
                local self = tostring(process.pid())
                local identity = "presentation-view-1"
                local viewer = assert(process.with_options({terminal = assert(output:grant())}):with_scope(scope):with_actor(assert(security.new_actor("viewer-person", {workspace_id = string.rep("a", 32)}))):spawn_monitored(
                    "bee.tests.harness:presentation_viewer", "bee:workers", {version = 1,
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
                        local mount = body.op == "attach" and assert(content:mount(sender, {observe = true, input = true, resize = true})) or nil
                        process.send(sender, "bee.session.window.reply", {ok = true, caller_token = body.caller_token, value = {mount = mount}})
                        if body.op == "attach" then
                            process.send(sender, "bee.session.window.review", {review = {approval_id = "review-request", title = "Use Progress?"}})
                        end
                        if body.op == "detach" then return end
                    end
                end)
                assert(process.send(viewer, "bee.test.viewer_release", {}))
                local event = channel.select({resized:case_receive(), finished:case_receive(), time.after("10s"):case_receive()})
                assert(event.ok and event.channel == resized, "viewer did not attach")
                local shown = assert(received(reviews), "the viewer did not show its owner's review")
                test.eq(assert(bounds.object(shown.review)).approval_id, "review-request")
                assert(process.send(producer, "bee.test.spoof_review", {viewer = tostring(viewer)}))
                local spoof = spoofed:receive()
                test.not_nil(spoof)
                assert(output:send({type = "close"}))
                local done = channel.select({finished:case_receive(), time.after("10s"):case_receive()})
                assert(done.channel == finished, "viewer did not close")
                local cleared = assert(received(reviews), "closing the viewer did not clear its banner")
                test.eq(cleared.review, false)
                output:close()
                process.unlisten(ready); process.unlisten(finished); process.unlisten(resized); process.unlisten(spoofed)
            end)
            process.cancel(producer, "presentation fixture complete")
            content:close()
            process.registry.unregister("bee.session.window/fixture-session", process.registry.LOCAL)
            process.unlisten(requests)
            apply(original)
            process.unlisten(reviews)
            if not ok then error(tostring(failure)) end
        end)
    end)
end
return test.run_cases(define_tests)
