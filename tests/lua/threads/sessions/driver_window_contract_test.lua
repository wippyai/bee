-- SPDX-License-Identifier: MIT
local test = require("test")
local harness = require("harness")
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local hooks = require("hooks")
local resolver = require("resolver")
local registry = require("registry")
local muse = require("muse")
local admission = require("admission")
type Object = {[string]: unknown}
local WORKSPACE = string.rep("a", 32)
local function define_tests()
    test.describe("Driver window session contract", function()
        for _, provider in ipairs({"agy", "grok", "muse"}) do
            test.it(provider .. " accepts window work and Stop returns its answer through session_await", function()
                local function run(plan: admission.Plan?)
                local pinned = assert(registry.snapshot())
                local profile = assert(resolver.profile(pinned, "bee.drivers." .. provider .. ".binding:binding", "window"))
                local policy = assert(pinned:get("bee.driver." .. provider .. ".security:launch_policy_" .. provider .. "_window"))
                local delivered = resolver.select_hooks(profile, assert(bounds.ids(assert(bounds.object(policy.data)).gateway_hooks, true)))
                test.not_nil(bounds.member("UserPromptSubmit", delivered))
                test.not_nil(bounds.member("Stop", delivered))
                local journal = harness.session_owner(WORKSPACE)
                local route: Object = {delivery = "hook", provider = provider}
                if plan then route.definition = plan.definition_ref; route.plan_digest = plan.plan_digest end
                local opened = harness.value(journal:call("session_create", {operation_key = harness.key(), route = route}))
                local stored = harness.value(journal:call("session_describe", {session = opened.session}))
                local attempt = "attempt:" .. string.rep(provider == "agy" and "a" or "b", 64)
                harness.value(journal:call("session_attach", {session = opened.session, attempt_id = attempt, operation_key = harness.key()}))
                local work = harness.value(journal:call("work_send", {session = opened.session, input = "Fixture prompt.", operation_key = harness.key()}))
                harness.value(journal:call("turn_reserve", {session = opened.session, operation_key = harness.key()}))
                local action = "action:" .. string.rep(provider == "agy" and "a" or "b", 64)
                local binding_id = plan and muse.binding(provider, tostring(opened.session), tostring(stored.thread_ref), attempt, action) or "binding-1"
                local function hook(event: string, payload: Object)
                    test.not_nil(hooks.normalize(event, payload))
                    local raw, err = funcs.new():with_scope(security.new_scope({})):with_actor(assert(security.new_actor("gateway"))):call(
                        "bee.tests.threads.sessions:hook_boundary_probe", {binding = {binding_id = binding_id, subject = opened.session,
                            action_id = action, attempt_id = attempt, thread_id = stored.thread_ref,
                            workspace_id = WORKSPACE}, outcome = {event = event, event_id = harness.key()}, payload = payload})
                    if err then error(tostring(err)) end
                    local reply = assert(bounds.object(raw))
                    if reply.ok ~= true then error(tostring(reply.error)) end
                end
                hook("UserPromptSubmit", {session_id = "provider-session", prompt = "[Bee message from sessions-owner]\nFixture prompt."})
                test.eq(harness.value(journal:call("work_describe", {work = work.work})).phase, "accepted")
                if plan then
                    local payload = muse.capture(provider, "PermissionRequest")
                    local actor = assert(security.new_actor("gateway"))
                    local future = assert(funcs.new():with_scope(security.new_scope({})):with_actor(actor):async(
                        "bee.tests.threads.sessions:hook_boundary_probe", {binding = {binding_id = binding_id, subject = opened.session,
                            action_id = action, attempt_id = attempt, thread_id = stored.thread_ref, workspace_id = WORKSPACE},
                            outcome = {event = "PermissionRequest", event_id = harness.key()}, payload = payload, transport = "hook_http"}))
                    test.not_nil(muse.decide(tostring(opened.session)))
                    future:response():receive()
                    local response, response_error = future:result()
                    test.is_nil(response_error)
                    local reply = assert(bounds.object(assert(response):data()))
                    test.eq(reply.ok, true)
                    local result = assert(bounds.object(reply.value))
                    local output = assert(bounds.object(result.hookSpecificOutput))
                    test.eq(assert(bounds.object(output.decision)).behavior, "allow")
                end
                local answer = provider .. " fixture answer."
                hook("Stop", provider == "grok" and {sessionId = "provider-session", lastAssistantMessage = answer}
                    or {session_id = "provider-session", last_assistant_message = answer})
                local actor = assert(security.new_actor(journal.id, {workspace_id = WORKSPACE}))
                local scope = security.new_scope({assert(security.policy("bee.tests.threads.sessions:await_test_caller"))})
                local raw, err = funcs.new():with_actor(actor):with_scope(scope):call("bee.threads.sessions.binding:await", {subject = work.work, timeout_ms = 0})
                if err then error(tostring(err)) end
                local reply = assert(bounds.object(raw))
                if reply.ok ~= true then error(tostring(assert(bounds.object(reply.error)).message)) end
                local ready = assert(bounds.object(reply.value))
                test.eq(ready.tag, "ready")
                local result = assert(bounds.object(ready.result))
                test.eq(result.outcome, "succeeded")
                test.eq(assert(bounds.object(result.value)).text, answer)
                end
                if provider ~= "grok" then muse.with_host(provider, run) else run(nil) end
            end)
        end
        for _, provider in ipairs({"agy", "claude", "muse"}) do
            test.it(provider .. " leaves a permission to the provider when its profile answers permissions there, with or without a Bee turn", function()
                muse.with_host(provider, function(admitted: admission.Plan?)
                local plan = assert(admitted)
                test.eq(plan.permission_answers, "provider")
                local journal = harness.session_owner(WORKSPACE)
                local opened = harness.value(journal:call("session_create", {operation_key = harness.key(),
                    route = {delivery = "hook", provider = provider, definition = plan.definition_ref, plan_digest = plan.plan_digest}}))
                local stored = harness.value(journal:call("session_describe", {session = opened.session}))
                local mark = ({agy = "c", claude = "d", muse = "e"})[provider]
                local attempt = "attempt:" .. string.rep(mark, 64)
                local action = "action:" .. string.rep(mark, 64)
                harness.value(journal:call("session_attach", {session = opened.session, attempt_id = attempt, operation_key = harness.key()}))
                local binding_id = muse.binding(provider, tostring(opened.session), tostring(stored.thread_ref), attempt, action)
                local function permission(): Object
                    local raw, err = funcs.new():with_scope(security.new_scope({})):with_actor(assert(security.new_actor("gateway"))):call(
                        "bee.tests.threads.sessions:hook_boundary_probe", {binding = {binding_id = binding_id, subject = opened.session,
                            action_id = action, attempt_id = attempt, thread_id = stored.thread_ref, workspace_id = WORKSPACE},
                            outcome = {event = "PermissionRequest", event_id = harness.key()}, payload = muse.capture("agy", "PermissionRequest"),
                            transport = "hook_http"})
                    if err then error(tostring(err)) end
                    return assert(bounds.object(raw))
                end
                local idle = permission()
                test.is_nil(idle.error)
                test.eq(idle.ok, true)
                test.eq(next(assert(bounds.object(idle.value))), nil)
                harness.value(journal:call("work_send", {session = opened.session, input = "Fixture prompt.", operation_key = harness.key()}))
                harness.value(journal:call("turn_reserve", {session = opened.session, operation_key = harness.key()}))
                local reserved = permission()
                test.is_nil(reserved.error)
                test.eq(next(assert(bounds.object(reserved.value))), nil)
                end, "provider")
            end)
        end
        for _, provider in ipairs({"agy", "claude"}) do
            test.it(provider .. " is told a refused Bee permission answer as a denial with its reason", function()
                muse.with_host(provider, function(admitted: admission.Plan?)
                local plan = assert(admitted)
                test.eq(plan.permission_answers, "ask")
                local journal = harness.session_owner(WORKSPACE)
                local opened = harness.value(journal:call("session_create", {operation_key = harness.key(),
                    route = {delivery = "hook", provider = provider, definition = plan.definition_ref, plan_digest = plan.plan_digest}}))
                local stored = harness.value(journal:call("session_describe", {session = opened.session}))
                local mark = ({agy = "f", claude = "9"})[provider]
                local attempt = "attempt:" .. string.rep(mark, 64)
                local action = "action:" .. string.rep(mark, 64)
                harness.value(journal:call("session_attach", {session = opened.session, attempt_id = attempt, operation_key = harness.key()}))
                local binding_id = muse.binding(provider, tostring(opened.session), tostring(stored.thread_ref), attempt, action)
                local raw, err = funcs.new():with_scope(security.new_scope({})):with_actor(assert(security.new_actor("gateway"))):call(
                    "bee.tests.threads.sessions:hook_boundary_probe", {binding = {binding_id = binding_id, subject = opened.session,
                        action_id = action, attempt_id = attempt, thread_id = stored.thread_ref, workspace_id = WORKSPACE},
                        outcome = {event = "PermissionRequest", event_id = harness.key()}, payload = muse.capture("agy", "PermissionRequest"),
                        transport = "hook_http"})
                if err then error(tostring(err)) end
                local reply = assert(bounds.object(raw))
                test.is_nil(reply.error)
                local output = assert(bounds.object(assert(bounds.object(reply.value)).hookSpecificOutput))
                test.eq(output.hookEventName, "PermissionRequest")
                local decision = assert(bounds.object(output.decision))
                test.eq(decision.behavior, "deny")
                test.eq(decision.message, "Bee answers this permission only within the session's current turn")
                end)
            end)
        end
    end)
end
return test.run_cases(define_tests)
