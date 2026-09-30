-- MIT. Interactive delivery enters through the authenticated Session boundary.
local test = require("test")
local harness = require("harness")
local funcs = require("funcs")
local security = require("security")
local WORKSPACE = string.rep("a", 32)
local function define_tests()
    test.describe("Sessions owner control boundary", function()
        test.it("accepts cancel, close and filtered list fields through the real owner", function()
            local journal = harness.session_owner(WORKSPACE)
            local opened = harness.value(journal:call("session_create", {operation_key = harness.key(), route = {}}))
            local work = harness.value(journal:call("work_send", {session = opened.session, input = "queued", operation_key = harness.key()}))
            local actor = assert(security.new_actor("sessions-owner", {workspace_id = WORKSPACE}))
            local scope = security.new_scope({assert(security.policy("bee.threads:session_owner_test_policy")),
                assert(security.policy("bee.tests.sessions:interactive_lifecycle_policy"))})
            local function call(method: string, request: unknown): {[string]: any}
                local raw, err = funcs.new():with_actor(actor):with_scope(scope):call("bee.sessions.binding:" .. method, request)
                if err then error(tostring(err)) end
                local reply = raw :: {[string]: any}
                if not reply.ok then error(tostring(reply.error and reply.error.message)) end
                return reply.value :: {[string]: any}
            end
            local cancelled = call("cancel", {work = work.work, reason = "regression", expected_incarnation = 1, operation_key = harness.key()})
            test.eq(cancelled.effect, "cancel")
            test.eq(harness.value(journal:call("work_describe", {work = work.work})).result.state, "cancelled")
            local page = call("list", {filter = {workspace = WORKSPACE, activity = "idle"}})
            local found = false
            for _, row in ipairs(page.items) do if row.session == opened.session then found = true end end
            test.is_true(found)
            local joined = call("join", {works = {work.work}, policy = "all_settled", operation_key = harness.key()})
            test.eq(joined.tag, "ready")
            test.eq(call("close", {session = opened.session, expected_incarnation = 1, operation_key = harness.key()}).effect, "close")
            test.eq(harness.value(journal:call("session_describe", {session = opened.session})).state, "closed")
        end)
    end)
    test.describe("Interactive Sessions", function()
        test.it("suspends only a proved exited attachment and preserves unfinished Work as uncertain", function()
            for _, state in ipairs({"running", "exited"}) do
                local journal = harness.session_owner(WORKSPACE)
                local opened = harness.value(journal:call("session_create", {operation_key = harness.key(), route = {delivery = "hook",
                    definition = "interactive-fixture", placement_methods = {reconcile = "bee.tests.sessions:interactive_" .. state}}}))
                harness.value(journal:call("session_attach", {session = opened.session, attempt_id = "interactive-lifecycle", operation_key = harness.key()}))
                local work = harness.value(journal:call("work_send", {session = opened.session, input = "unfinished", operation_key = harness.key()}))
                local turn = harness.value(journal:call("turn_reserve", {session = opened.session, operation_key = harness.key()}))
                local pulled = harness.value(journal:call("turn_pull", {turn = turn.turn, claim = turn.claim}))
                harness.value(journal:call("turn_accept", {turn = turn.turn, claim = turn.claim, input_digest = pulled.input_digest,
                    checkpoint = {attempt_id = "interactive-lifecycle"}, operation_key = harness.key()}))
                local actor = assert(security.new_actor("sessions-owner", {workspace_id = WORKSPACE}))
                local policies = {assert(security.policy("bee.threads:session_owner_test_policy")), assert(security.policy("bee.tests.sessions:interactive_lifecycle_policy"))}
                local raw, err = funcs.new():with_actor(actor):with_scope(security.new_scope(policies)):call("bee.sessions.binding:detach",
                    {session = opened.session, attempt_id = "interactive-lifecycle", operation_key = harness.key()})
                if err then error(tostring(err)) end
                local reply = raw :: {[string]: any}
                test.eq(reply.ok, state == "exited")
                local current = harness.value(journal:call("session_describe", {session = opened.session}))
                test.eq(current.state, state == "exited" and "suspended" or "active")
                local pending = harness.value(journal:call("work_describe", {work = work.work}))
                if state == "exited" then test.not_nil(pending.uncertainty) else test.is_nil(pending.uncertainty) end
            end
        end)
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
