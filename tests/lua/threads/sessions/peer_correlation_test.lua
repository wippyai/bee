-- MIT
local test = require("test")
local harness = require("harness")
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local record = require("record")
local WORKSPACE = string.rep("a", 32)
local function define_tests()
    test.describe("Peer Sessions inbox correlation", function()
        for _, via_hook in ipairs({false, true}) do
            test.it("commits one inbox request and its correlated reply with the durable work" .. (via_hook and " through observer hooks" or ""), function()
                local owner = harness.session_owner(WORKSPACE)
                local opened = harness.value(owner:call("session_create", {operation_key = harness.key(), route = {delivery = "hook"}}))
                if via_hook then harness.value(owner:call("session_attach", {session = opened.session, attempt_id = "fixture", operation_key = harness.key()})) end
                local described = harness.value(owner:call("session_describe", {session = opened.session}))
                local source = "bs:source-bee:" .. WORKSPACE .. ":agent"
                local peer = funcs.new():with_actor(assert(security.new_actor("bee.hive.member.source-bee:agent", {node = "source-bee", workspace_id = WORKSPACE})))
                    :with_scope(assert(security.new_scope({assert(security.policy("bee.tests.threads:client_policy")), assert(security.policy("bee.threads.security:sessions_owner"))})))
                    :with_context({["bee.hive.caller"] = {node = "source-bee", allowance_revision = 1,
                        origin = {session = source, thread_id = "source-thread", workspace_id = WORKSPACE}}})
                local key = harness.key()
                local function send(): {[string]: unknown}
                    local raw, err = peer:call("bee.threads.binding:work_send", {session = opened.session, input = "hello", operation_key = key})
                    assert(not err, tostring(err))
                    return harness.value(harness.decode_reply(raw))
                end
                local receipt = send()
                test.eq(send().work, receipt.work)
                local recipient = harness.principal(tostring(opened.session), {}, WORKSPACE)
                local request = harness.value(recipient:call("inbox_list", {thread_id = described.thread_ref, action_id = opened.session, after_sequence = 0}))
                test.eq(#request.items, 1)
                local item = request.items[1]
                test.eq(item.message_id, receipt.work)
                test.eq(item.sender_action_id, source)
                test.eq(item.sender_node_id, "source-bee")
                test.eq(item.sender_thread_id, "source-thread")
                local turn = harness.value(owner:call("turn_reserve", {session = opened.session, operation_key = harness.key()}))
                local pulled = harness.value(owner:call("turn_pull", {turn = turn.turn, claim = turn.claim}))
                harness.value(owner:call("turn_accept", {turn = turn.turn, claim = turn.claim, input_digest = pulled.input_digest,
                    checkpoint = {attempt_id = "fixture"}, operation_key = harness.key()}))
                if via_hook then
                    local hook = funcs.new():with_actor(assert(security.new_actor(tostring(opened.session), {workspace_id = WORKSPACE})))
                        :with_scope(assert(security.new_scope({assert(security.policy("bee.gateway.security:session_boundary_policy"))})))
                    local raw, err = hook:call("bee.threads.sessions.binding:hook_boundary", {session = opened.session, event = "Stop",
                        attempt_id = "fixture", answer = "reply", operation_key = harness.key()})
                    test.is_nil(err, tostring(err))
                    test.is_true(assert(bounds.object(raw)).ok == true)
                else
                    harness.value(owner:call("work_settle", {turn = turn.turn, claim = turn.claim, operation_key = harness.key(),
                        result = {state = "succeeded", schema = "bee:Text@1", value = {text = "reply"}}}))
                end
                local after = harness.value(recipient:call("inbox_list", {thread_id = described.thread_ref, action_id = opened.session, after_sequence = 0}))
                test.eq(after.items[1].state, "replied")
                local page = harness.value(owner:call("read_after", {thread_id = described.thread_ref, cursor = 0}))
                local reply: {[string]: unknown}? = nil
                for _, raw in ipairs(page.records) do
                    local decoded = assert(record.decode(raw))
                    if decoded.kind == "message" and decoded.body.message_kind == "reply" then reply = decoded.body end
                end
                test.not_nil(reply)
                local correlation = assert(bounds.object(assert(reply).in_reply_to))
                test.eq(correlation.thread_id, described.thread_ref)
                test.eq(correlation.record_id, item.record_id)
                key = harness.key()
                local cancelled = send()
                harness.value(owner:call("work_cancel", {work = cancelled.work, operation_key = harness.key()}))
                local cancelled_inbox = harness.value(recipient:call("inbox_list", {thread_id = described.thread_ref, action_id = opened.session, after_sequence = 0}))
                test.eq(cancelled_inbox.items[2].state, "replied")
            end)
        end
    end)
end
return test.run_cases(define_tests)
