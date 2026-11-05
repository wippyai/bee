-- SPDX-License-Identifier: MIT
local test = require("test")
local hash = require("hash")
local harness = require("harness")
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local hooks = require("hooks")
local resolver = require("resolver")
local registry = require("registry")
local muse = require("muse")
local resolution = require("resolution")
type Object = {[string]: unknown}
local WORKSPACE = string.rep("a", 32)
local function define_tests()
    test.describe("Driver window session contract", function()
        for _, provider in ipairs({"agy", "grok", "muse"}) do
            test.it(provider .. " accepts window work and Stop returns its answer through session_await", function()
                local function run(plan: resolution.Plan?)
                local pinned = assert(registry.snapshot())
                local profile = assert(resolver.profile(pinned, "bee.drivers." .. provider .. ".binding:binding", "window"))
                local policy = assert(pinned:get("bee.driver." .. provider .. ".security:launch_policy_" .. provider .. "_window"))
                local delivered = resolver.select_hooks(profile, assert(bounds.ids(assert(bounds.object(policy.data)).gateway_hooks, true)))
                test.not_nil(bounds.member("UserPromptSubmit", delivered))
                test.not_nil(bounds.member("Stop", delivered))
                local journal = harness.session_owner(WORKSPACE)
                local route: Object = plan and muse.route(plan) or {delivery = "hook", provider = provider}
                local opened = harness.value(journal:call("session_create", {operation_key = harness.key(), route = route}))
                local stored = harness.value(journal:call("session_describe", {session = opened.session}))
                local attempt = "attempt:" .. string.rep(provider == "agy" and "a" or "b", 64)
                harness.value(journal:call("session_attach", {session = opened.session, attempt_id = attempt, operation_key = harness.key()}))
                local work = harness.value(journal:call("work_send", {session = opened.session, input = "Fixture prompt.", operation_key = harness.key()}))
                local reserved = harness.value(journal:call("turn_reserve", {session = opened.session, operation_key = harness.key()}))
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
                hook("UserPromptSubmit", {session_id = "provider-session", prompt = "[Bee message #" .. assert(hash.sha256(tostring(reserved.turn))):sub(1, 12) .. " from sessions-owner]\nFixture prompt."})
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
                muse.with_host(provider, function(admitted: resolution.Plan?)
                local plan = assert(admitted)
                test.eq(plan.permission_answers, "provider")
                local journal = harness.session_owner(WORKSPACE)
                local opened = harness.value(journal:call("session_create", {operation_key = harness.key(),
                    route = muse.route(plan)}))
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
        test.it("agy answers a permission hook under the saved profile its window was admitted with", function()
            muse.with_host("agy", function(_: resolution.Plan?)
            local raw_saved, save_error = funcs.call("bee.harness.binding:call", {operation = "put", workspace_id = WORKSPACE,
                profile_id = "window-saved-profile", expected_revision = 0, idempotency_key = harness.key(),
                profile = {schema_revision = "bee.agent-profile@3", name = "Saved Agy window",
                    definition_ref = "bee.driver.agy.profiles:default_window", driver_binding_ref = "bee.drivers.agy.binding:binding",
                    provider = {}, bee = {permission_answers = "provider"}, placement = {kind = "native", home = "machine"}}})
            if save_error then error(tostring(save_error)) end
            local saved = assert(bounds.object(raw_saved))
            test.eq(saved.ok, true, tostring(saved.error and assert(bounds.object(saved.error)).message))
            local plan, refused = resolution.resolve("bee.driver.agy.profiles:default_window", "window", WORKSPACE, "window-saved-profile", 1)
            assert(plan, tostring(refused and refused.error and refused.error.message))
            test.eq(plan.permission_answers, "provider")
            local journal = harness.session_owner(WORKSPACE)
            local opened = harness.value(journal:call("session_create", {operation_key = harness.key(),
                route = muse.route(plan)}))
            local stored = harness.value(journal:call("session_describe", {session = opened.session}))
            local attempt = "attempt:" .. string.rep("7", 64)
            local action = "action:" .. string.rep("7", 64)
            harness.value(journal:call("session_attach", {session = opened.session, attempt_id = attempt, operation_key = harness.key()}))
            local binding_id = muse.binding("agy", tostring(opened.session), tostring(stored.thread_ref), attempt, action)
            local raw, err = funcs.new():with_scope(security.new_scope({})):with_actor(assert(security.new_actor("gateway"))):call(
                "bee.tests.threads.sessions:hook_boundary_probe", {binding = {binding_id = binding_id, subject = opened.session,
                    action_id = action, attempt_id = attempt, thread_id = stored.thread_ref, workspace_id = WORKSPACE},
                    outcome = {event = "PermissionRequest", event_id = harness.key()}, payload = muse.capture("agy", "PermissionRequest"),
                    transport = "hook_http"})
            if err then error(tostring(err)) end
            local reply = assert(bounds.object(raw))
            test.is_nil(reply.error)
            test.eq(reply.ok, true)
            local value = assert(bounds.object(reply.value))
            local output = bounds.object(value.hookSpecificOutput)
            local decision = output and bounds.object(output.decision)
            test.is_nil(decision and decision.message)
            test.eq(next(value), nil, "the provider answers the permission; Bee adds no decision")
            end, "provider")
        end)
        for _, provider in ipairs({"agy", "claude"}) do
            test.it(provider .. " is told a refused Bee permission answer as a denial with its reason", function()
                muse.with_host(provider, function(admitted: resolution.Plan?)
                local plan = assert(admitted)
                test.eq(plan.permission_answers, "ask")
                local journal = harness.session_owner(WORKSPACE)
                local opened = harness.value(journal:call("session_create", {operation_key = harness.key(),
                    route = muse.route(plan)}))
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
        local function admitted_window(plan: resolution.Plan, mark: string): (Object, Object, string, string, string)
            local journal = harness.session_owner(WORKSPACE)
            local opened = harness.value(journal:call("session_create", {operation_key = harness.key(), route = muse.route(plan)}))
            local stored = harness.value(journal:call("session_describe", {session = opened.session}))
            local attempt, action = "attempt:" .. string.rep(mark, 64), "action:" .. string.rep(mark, 64)
            harness.value(journal:call("session_attach", {session = opened.session, attempt_id = attempt, operation_key = harness.key()}))
            local binding_id = muse.binding("agy", tostring(opened.session), tostring(stored.thread_ref), attempt, action)
            return opened, stored, attempt, action, binding_id
        end
        local function session_get(session: string): Object
            local actor = assert(security.new_actor(harness.session_owner(WORKSPACE).id, {workspace_id = WORKSPACE}))
            local scope = security.new_scope({assert(security.policy("bee.tests.threads.sessions:await_test_caller"))})
            local raw, err = funcs.new():with_actor(actor):with_scope(scope):with_context({["bee.workspace_id"] = WORKSPACE}):call("bee.threads.sessions.binding:get", {session = session})
            if err then error(tostring(err)) end
            local reply = assert(bounds.object(raw))
            if reply.ok ~= true then error(tostring(assert(bounds.object(reply.error)).message)) end
            return assert(bounds.object(assert(bounds.object(reply.value)).value))
        end
        local function denial(reply: Object): string?
            local value = bounds.object(reply.value)
            local output = value and bounds.object(value.hookSpecificOutput)
            local decision = output and bounds.object(output.decision)
            return decision and decision.behavior == "deny" and bounds.text(decision.message, 4096) or nil
        end
        test.it("a window admitted with an empty override set digests and answers as one admitted with none", function()
            muse.with_host("agy", function(admitted: resolution.Plan?)
                local plan, refused = resolution.resolve("bee.driver.agy.profiles:default_window", "window", WORKSPACE, nil, nil, nil, nil, nil, nil, {})
                assert(plan, tostring(refused and refused.error and refused.error.message))
                test.eq(plan.plan_digest, assert(admitted).plan_digest)
                local opened, stored, attempt, action, binding_id = admitted_window(plan, "1")
                local reply = muse.permission(tostring(opened.session), tostring(stored.thread_ref), attempt, action, binding_id, muse.capture("agy", "PermissionRequest"))
                test.is_nil(denial(reply))
                test.eq(reply.ok, true)
                test.eq(next(assert(bounds.object(reply.value))), nil)
            end, "provider")
        end)
        test.it("a window keeps answering permissions under its admitted plan after its driver declaration changes", function()
            muse.with_host("agy", function(admitted: resolution.Plan?)
                local plan = assert(admitted)
                local opened, stored, attempt, action, binding_id = admitted_window(plan, "2")
                local DECLARATION = "bee.drivers.agy.profiles:profiles"
                local original = assert(registry.get(DECLARATION))
                local changed = assert(registry.get(DECLARATION))
                local declared = assert(bounds.object(assert(bounds.object(changed.data)).driver))
                declared.implementation_version = "999.0.0"
                local changes = assert(registry.snapshot()):changes()
                assert(changes:update(changed)); assert(changes:apply())
                local ok, failure = pcall(function()
                    local current = assert((resolution.resolve(plan.definition_ref, "window", WORKSPACE)))
                    test.eq(current.plan_digest ~= plan.plan_digest, true, "the upgrade changes the plan a new launch is admitted under")
                    local reply = muse.permission(tostring(opened.session), tostring(stored.thread_ref), attempt, action, binding_id, muse.capture("agy", "PermissionRequest"))
                    test.is_nil(denial(reply))
                    test.eq(reply.ok, true)
                    test.eq(next(assert(bounds.object(reply.value))), nil)
                end)
                local restore = assert(registry.snapshot()):changes()
                assert(restore:update(original)); assert(restore:apply())
                assert(ok, tostring(failure))
            end, "provider")
        end)
        test.it("a window refuses permissions once its saved profile changes and says to restart the session", function()
            muse.with_host("agy", function(_: resolution.Plan?)
                local function put(revision: integer, name: string)
                    local raw, err = funcs.call("bee.harness.binding:call", {operation = "put", workspace_id = WORKSPACE,
                        profile_id = "window-changed-profile", expected_revision = revision, idempotency_key = harness.key(),
                        profile = {schema_revision = "bee.agent-profile@3", name = name,
                            definition_ref = "bee.driver.agy.profiles:default_window", driver_binding_ref = "bee.drivers.agy.binding:binding",
                            provider = {}, bee = {permission_answers = "provider"}, placement = {kind = "native", home = "machine"}}})
                    if err then error(tostring(err)) end
                    local saved = assert(bounds.object(raw))
                    test.eq(saved.ok, true, tostring(saved.error and assert(bounds.object(saved.error)).message))
                end
                put(0, "Agy window")
                local plan, refused = resolution.resolve("bee.driver.agy.profiles:default_window", "window", WORKSPACE, "window-changed-profile", 1)
                assert(plan, tostring(refused and refused.error and refused.error.message))
                local opened, stored, attempt, action, binding_id = admitted_window(plan, "3")
                local payload = muse.capture("agy", "PermissionRequest")
                local before = muse.permission(tostring(opened.session), tostring(stored.thread_ref), attempt, action, binding_id, payload)
                test.is_nil(denial(before))
                put(1, "Agy window renamed")
                local after = muse.permission(tostring(opened.session), tostring(stored.thread_ref), attempt, action, binding_id, payload)
                test.eq(denial(after), "The saved profile this session uses changed; restart this session to apply the changed profile.")
                test.eq(session_get(tostring(opened.session)).admission_refusal, "The saved profile this session uses changed; restart this session to apply the changed profile.")
                local resumed_plan, resume_refused = resolution.resolve("bee.driver.agy.profiles:default_window", "window", WORKSPACE, "window-changed-profile", 2)
                assert(resumed_plan, tostring(resume_refused and resume_refused.error and resume_refused.error.message))
                local journal = harness.session_owner(WORKSPACE)
                local resumed_attempt, resumed_action = "attempt:" .. string.rep("4", 64), "action:" .. string.rep("4", 64)
                harness.value(journal:call("session_attach", {session = opened.session, attempt_id = resumed_attempt,
                    admission = resolution.session_admission(resumed_plan), operation_key = harness.key()}))
                local route = assert(bounds.object(harness.value(journal:call("session_describe", {session = opened.session})).route))
                test.eq(route.saved_profile_revision, 2)
                test.eq(route.plan_digest, resumed_plan.plan_digest)
                local resumed_binding = muse.binding("agy", tostring(opened.session), tostring(stored.thread_ref), resumed_attempt, resumed_action)
                local resumed = muse.permission(tostring(opened.session), tostring(stored.thread_ref), resumed_attempt, resumed_action, resumed_binding, payload)
                test.is_nil(denial(resumed))
                test.eq(resumed.ok, true)
                test.is_nil(session_get(tostring(opened.session)).admission_refusal)
            end, "provider")
        end)
        test.it("a window whose saved profile is gone refuses its hooks and its restore with the same reason", function()
            muse.with_host("agy", function(_: resolution.Plan?)
                local raw, err = funcs.call("bee.harness.binding:call", {operation = "put", workspace_id = WORKSPACE,
                    profile_id = "window-removed-profile", expected_revision = 0, idempotency_key = harness.key(),
                    profile = {schema_revision = "bee.agent-profile@3", name = "Agy window removed",
                        definition_ref = "bee.driver.agy.profiles:default_window", driver_binding_ref = "bee.drivers.agy.binding:binding",
                        provider = {}, bee = {permission_answers = "provider"}, placement = {kind = "native", home = "machine"}}})
                if err then error(tostring(err)) end
                test.eq(assert(bounds.object(raw)).ok, true)
                local plan = assert((resolution.resolve("bee.driver.agy.profiles:default_window", "window", WORKSPACE, "window-removed-profile", 1)))
                local opened, stored, attempt, action, binding_id = admitted_window(plan, "5")
                local removed, remove_error = funcs.call("bee.harness.binding:call", {operation = "remove", workspace_id = WORKSPACE,
                    profile_id = "window-removed-profile", expected_revision = 1, idempotency_key = harness.key()})
                if remove_error then error(tostring(remove_error)) end
                test.eq(assert(bounds.object(removed)).ok, true)
                local reason = "The saved profile this session uses was deleted; start a new session."
                local reply = muse.permission(tostring(opened.session), tostring(stored.thread_ref), attempt, action, binding_id, muse.capture("agy", "PermissionRequest"))
                test.eq(denial(reply), reason)
                local revision, refused = resolution.saved_revision(WORKSPACE, "window-removed-profile")
                test.is_nil(revision)
                test.eq(assert(refused).error and assert(refused.error).message, reason)
                local _, never_saved = resolution.saved_revision(WORKSPACE, "window-never-saved-profile")
                test.eq(assert(never_saved).error and assert(never_saved.error).message, reason)
                local _, resolve_refused = resolution.resolve("bee.driver.agy.profiles:default_window", "window", WORKSPACE, "window-removed-profile", 1)
                test.eq(assert(resolve_refused).error and assert(resolve_refused.error).message, reason)
                test.eq(resolution.resumable("bee.driver.agy.profiles:default_window", WORKSPACE, "window-removed-profile"), reason)
                test.eq(resolution.resumable("bee.driver.agy.profiles:missing_window", WORKSPACE, nil),
                    "This session's launch definition bee.driver.agy.profiles:missing_window is no longer installed; start a new session.")
                test.is_nil(resolution.resumable("bee.driver.agy.profiles:default_window", WORKSPACE, nil))
            end, "provider")
        end)
    end)
end
return test.run_cases(define_tests)
