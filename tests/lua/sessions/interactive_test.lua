-- MIT. Interactive delivery enters through the authenticated Session boundary.
local test = require("test")
local harness = require("harness")
local funcs = require("funcs")
local security = require("security")
local WORKSPACE = string.rep("a", 32)
local function define_tests()
    test.describe("Interactive Sessions", function()
        test.it("delivers authenticated peer input once at a turn boundary and keeps busy input queued", function()
            local journal = harness.session_owner(WORKSPACE)
            local opened = harness.value(journal:call("session_create", {operation_key = harness.key(), route = {delivery = "hook"}}))
            harness.value(journal:call("session_attach", {session = opened.session, attempt_id = "interactive-one", operation_key = harness.key()}))
            local session_ref = opened.session :: string
            local peer = harness.principal("bs:node:" .. WORKSPACE .. ":peer", {"bee.threads:session_owner_test_policy"}, WORKSPACE)
            local first = harness.value(peer:call("work_send", {session = opened.session, input = "reply to this peer", operation_key = harness.key()}))
            local policies = {assert(security.policy("bee.gateway.security:session_boundary_policy"))}
            local function boundary(actor_id: string, event: string, operation_key: string, attempt: string?): {[string]: any}
                local actor = assert(security.new_actor(actor_id, {workspace_id = WORKSPACE}))
                local raw, err = funcs.new():with_actor(actor):with_scope(security.new_scope(policies)):call("bee.sessions.binding:hook_boundary",
                    {session = opened.session, event = event, operation_key = operation_key, attempt_id = attempt or "interactive-one"})
                if err then error(tostring(err)) end
                return raw :: {[string]: any}
            end
            test.is_false(boundary("forged", "UserPromptSubmit", harness.key()).ok)
            test.is_false(boundary(session_ref, "UserPromptSubmit", harness.key(), "stale-window").ok)
            local start = harness.key()
            local received = boundary(session_ref, "UserPromptSubmit", start)
            if not received.ok then error(tostring(received.error and received.error.message)) end
            test.is_true(received.value.additional_context:find(peer.id, 1, true) ~= nil)
            test.is_true(received.value.additional_context:find("reply to this peer", 1, true) ~= nil)
            test.eq(boundary(session_ref, "UserPromptSubmit", start).value.additional_context, received.value.additional_context)
            local second = harness.value(peer:call("work_send", {session = opened.session, input = "next message", operation_key = harness.key()}))
            test.is_nil(boundary(session_ref, "UserPromptSubmit", harness.key()).value.additional_context)
            test.eq(harness.value(journal:call("work_describe", {work = second.work})).phase, "queued")
            test.is_true(boundary(session_ref, "Stop", harness.key()).ok)
            test.eq(harness.value(journal:call("work_describe", {work = first.work})).phase, "settled")
            test.is_nil(boundary(session_ref, "UserPromptSubmit", start).value.additional_context)
            test.is_true(boundary(session_ref, "UserPromptSubmit", harness.key()).value.additional_context:find("next message", 1, true) ~= nil)
        end)
    end)
end
return test.run_cases(define_tests)
