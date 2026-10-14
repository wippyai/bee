-- SPDX-License-Identifier: MIT
local test = require("test")
local harness = require("harness")
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local opencode_hooks = require("opencode_hooks")
local WORKSPACE = string.rep("a", 32)
local function owner_text(input: string, sender: string): string
    return "[Bee message from " .. sender .. "]\n" .. input
end
local function define_tests()
    test.describe("OpenCode hook carrier settlement", function()
        test.it("settles reserved OpenCode peer work from observer prompt and idle events", function()
            local journal = harness.session_owner(WORKSPACE)
            local opened = harness.value(journal:call("session_create", {operation_key = harness.key(), route = {delivery = "hook"}}))
            local attempt = "attempt:" .. string.rep("b", 64)
            harness.value(journal:call("session_attach", {session = opened.session, attempt_id = attempt, operation_key = harness.key()}))
            local work = harness.value(journal:call("work_send", {session = opened.session, input = "e2e thread handshake", operation_key = harness.key()}))
            harness.value(journal:call("turn_reserve", {session = opened.session, operation_key = harness.key()}))
            test.eq(harness.value(journal:call("work_describe", {work = work.work})).phase, "reserved")
            local capture = opencode_hooks.capture({prompt = owner_text("e2e thread handshake", "sessions-owner"), answer = "Acknowledged e2e thread handshake"})
            test.is_nil(capture.error)
            for _, payload in ipairs(harness.objects(capture.rows, 16)) do
                local raw, err = funcs.new():with_scope(security.new_scope({})):with_actor(assert(security.new_actor("gateway"))):call(
                    "bee.tests.sessions:hook_boundary_probe", {binding = {binding_id = "binding-1", subject = opened.session,
                        action_id = "action:" .. string.rep("b", 64), attempt_id = attempt, thread_id = "thread:" .. string.rep("b", 64), workspace_id = WORKSPACE},
                        outcome = {event = payload.hook_event_name, event_id = harness.key()}, payload = payload})
                if err then error(tostring(err)) end
                test.is_true(assert(bounds.object(raw)).ok)
            end
            local settled = harness.value(journal:call("work_describe", {work = work.work}))
            test.eq(settled.phase, "settled")
            test.eq(settled.result.state, "succeeded")
            test.eq(settled.result.value.text, "Acknowledged e2e thread handshake")
            local awaited = harness.value(journal:call("work_await", {works = {work.work}, wait_ms = 0}))
            test.eq(awaited.works[1].result.value.text, "Acknowledged e2e thread handshake")
        end)
    end)
end
return test.run_cases(define_tests)
