-- SPDX-License-Identifier: MIT
local test = require("test")
local harness = require("harness")
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local hooks = require("hooks")
local resolver = require("resolver")
local registry = require("registry")
type Object = {[string]: unknown}
local WORKSPACE = string.rep("a", 32)
local function define_tests()
    test.describe("Driver window session contract", function()
        for _, provider in ipairs({"agy", "grok", "muse"}) do
            test.it(provider .. " accepts window work and Stop returns its answer through session_await", function()
                local pinned = assert(registry.snapshot())
                local profile = assert(resolver.profile(pinned, "bee.driver." .. provider .. ".binding:binding", "window"))
                local policy = assert(pinned:get("bee.driver." .. provider .. ".security:launch_policy_" .. provider .. "_window"))
                local delivered = resolver.select_hooks(profile, assert(bounds.ids(assert(bounds.object(policy.data)).gateway_hooks, true)))
                test.not_nil(bounds.member("UserPromptSubmit", delivered))
                test.not_nil(bounds.member("Stop", delivered))
                local journal = harness.session_owner(WORKSPACE)
                local opened = harness.value(journal:call("session_create", {operation_key = harness.key(), route = {delivery = "hook"}}))
                local attempt = "attempt:" .. string.rep("a", 64)
                harness.value(journal:call("session_attach", {session = opened.session, attempt_id = attempt, operation_key = harness.key()}))
                local work = harness.value(journal:call("work_send", {session = opened.session, input = "Fixture prompt.", operation_key = harness.key()}))
                harness.value(journal:call("turn_reserve", {session = opened.session, operation_key = harness.key()}))
                local function hook(event: string, payload: Object)
                    test.not_nil(hooks.normalize(event, payload))
                    local raw, err = funcs.new():with_scope(security.new_scope({})):with_actor(assert(security.new_actor("gateway"))):call(
                        "bee.tests.sessions:hook_boundary_probe", {binding = {binding_id = "binding-1", subject = opened.session,
                            action_id = "action:" .. string.rep("a", 64), attempt_id = attempt, thread_id = "thread:" .. string.rep("a", 64),
                            workspace_id = WORKSPACE}, outcome = {event = event, event_id = harness.key()}, payload = payload})
                    if err then error(tostring(err)) end
                    local reply = assert(bounds.object(raw))
                    if reply.ok ~= true then error(tostring(reply.error)) end
                end
                hook("UserPromptSubmit", {session_id = "provider-session", prompt = "[Bee message from sessions-owner]\nFixture prompt."})
                test.eq(harness.value(journal:call("work_describe", {work = work.work})).phase, "accepted")
                local answer = provider .. " fixture answer."
                hook("Stop", provider == "grok" and {sessionId = "provider-session", lastAssistantMessage = answer}
                    or {session_id = "provider-session", last_assistant_message = answer})
                local actor = assert(security.new_actor(journal.id, {workspace_id = WORKSPACE}))
                local scope = security.new_scope({assert(security.policy("bee.tests.sessions:await_test_caller"))})
                local raw, err = funcs.new():with_actor(actor):with_scope(scope):call("bee.threads.sessions.binding:await", {subject = work.work, timeout_ms = 0})
                if err then error(tostring(err)) end
                local reply = assert(bounds.object(raw))
                if reply.ok ~= true then error(tostring(assert(bounds.object(reply.error)).message)) end
                local ready = assert(bounds.object(reply.value))
                test.eq(ready.tag, "ready")
                local result = assert(bounds.object(ready.result))
                test.eq(result.outcome, "succeeded")
                test.eq(assert(bounds.object(result.value)).text, answer)
            end)
        end
    end)
end
return test.run_cases(define_tests)
