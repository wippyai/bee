-- MIT. Separate action inboxes grant delivery without thread membership.
local test = require("test")
local harness = require("harness")
local sends = require("sends")
local system = require("system")
local WORKSPACE = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
local function admitted(principal: string): {[string]: unknown}
    local value = harness.admitted()
    value.principal_id = principal
    return value
end
local function define_tests()
    test.describe("Action inbox", function()
        test.it("checks the send grant and owner acceptance, deduplicates, acknowledges and correlates a cross-thread reply", function()
            local a = harness.principal("agent-a", {"bee.security.threads:thread_create_policy", "bee.security.threads:thread_lifecycle_policy", "bee.threads:inbox_send_test_policy"}, WORKSPACE)
            local b = harness.principal("agent-b", {"bee.security.threads:thread_create_policy", "bee.security.threads:thread_lifecycle_policy", "bee.threads:inbox_send_test_policy"}, WORKSPACE)
            local no_grant = harness.principal("agent-a", {"bee.security.threads:thread_create_policy", "bee.security.threads:thread_lifecycle_policy"}, WORKSPACE)
            local a_thread = harness.thread(a, "A")
            local b_thread = harness.thread(b, "B")
            local native = system.node.id()
            local node_id = native and native ~= "" and native or "local"
            harness.value(a:call("admit_action", {thread_id = a_thread, idempotency_key = harness.key(), action_id = "action-a", admitted = admitted("agent-a")}))
            harness.value(b:call("admit_action", {thread_id = b_thread, idempotency_key = harness.key(), action_id = "action-b", admitted = admitted("agent-b")}))
            test.eq(harness.code(a:call("get", {thread_id = b_thread})), "DENIED")
            local content = {text = "hello"}
            local request = {thread_id = b_thread, target_action_id = "action-b", sender_thread_id = a_thread, sender_action_id = "action-a", node_id = node_id,
                grant_epoch = 1, idempotency_key = harness.key(), message_id = "hello-1", content = content,
                payload_digest = assert(sends.payload_digest({message_id = "hello-1", content = content}))}
            local before_acceptance = a:call("inbox_send", request)
            if not before_acceptance.ok and before_acceptance.error and before_acceptance.error.code ~= "DENIED" then error(before_acceptance.error.message) end
            test.eq(harness.code(before_acceptance), "DENIED")
            local accepted = harness.value(b:call("inbox_accept", {thread_id = b_thread, action_id = "action-b", sender_id = "agent-a", allow = true,
                expected_epoch = 0, idempotency_key = harness.key()}))
            test.eq(accepted.grant_epoch, 1)
            test.eq(harness.code(no_grant:call("inbox_send", request)), "DENIED")
            local sent = harness.value(a:call("inbox_send", request))
            test.eq(sent.inbox_sequence, 1)
            test.eq(sent.state, "committed")
            local replay = a:call("inbox_send", request)
            test.is_true(replay.replayed)
            test.eq(harness.value(replay).record_id, sent.record_id)
            local widened = harness.value(b:call("inbox_accept", {thread_id = b_thread, action_id = "action-b", sender_class = "bee.application", allow = true,
                expected_epoch = 1, idempotency_key = harness.key()}))
            test.eq(widened.grant_epoch, 2)
            local stale: {[string]: unknown} = {}
            for key, value in pairs(request) do stale[key] = value end
            stale.idempotency_key = harness.key()
            stale.message_id = "hello-stale"
            stale.payload_digest = assert(sends.payload_digest({message_id = "hello-stale", content = content}))
            test.eq(harness.code(a:call("inbox_send", stale)), "CONFLICT")
            local changed: {[string]: unknown} = {}
            for key, value in pairs(request) do changed[key] = value end
            changed.content = {text = "different"}
            test.eq(harness.code(a:call("inbox_send", changed)), "INVALID_ARGUMENT")
            test.eq(harness.code(a:call("read_after", {thread_id = b_thread, cursor = 0})), "DENIED")
            local inbox = harness.value(b:call("inbox_list", {thread_id = b_thread, action_id = "action-b", after_sequence = 0}))
            test.eq(#inbox.items, 1)
            test.eq(inbox.items[1].record_id, sent.record_id)
            test.eq(inbox.items[1].payload_digest, request.payload_digest)
            local acknowledged = harness.value(b:call("inbox_ack", {thread_id = b_thread, action_id = "action-b", inbox_sequence = 1,
                idempotency_key = harness.key()}))
            test.eq(acknowledged.state, "acknowledged")
            harness.value(a:call("inbox_accept", {thread_id = a_thread, action_id = "action-a", sender_id = "agent-b", allow = true,
                expected_epoch = 0, idempotency_key = harness.key()}))
            local reply_content = {text = "world"}
            local answer = harness.value(b:call("inbox_reply", {thread_id = a_thread, target_action_id = "action-a", sender_thread_id = b_thread, sender_action_id = "action-b",
                node_id = node_id, grant_epoch = 1, idempotency_key = harness.key(), message_id = "reply-1", content = reply_content,
                payload_digest = assert(sends.payload_digest({message_id = "reply-1", content = reply_content})),
                in_reply_to = {thread_id = b_thread, record_id = sent.record_id}, outcome = "succeeded"}))
            test.eq(answer.state, "committed")
            local a_inbox = harness.value(a:call("inbox_list", {thread_id = a_thread, action_id = "action-a", after_sequence = 0}))
            test.eq(a_inbox.items[1].in_reply_to.record_id, sent.record_id)
            test.eq(harness.value(b:call("inbox_list", {thread_id = b_thread, action_id = "action-b", after_sequence = 0})).items[1].state, "replied")
            local c_id = "bee.application:" .. WORKSPACE .. ":window-c"
            local c = harness.principal(c_id, {"bee.security.threads:thread_create_policy", "bee.security.threads:thread_lifecycle_policy", "bee.threads:inbox_send_test_policy"}, WORKSPACE)
            local c_thread = harness.thread(c, "C")
            harness.value(c:call("admit_action", {thread_id = c_thread, idempotency_key = harness.key(), action_id = "action-c", admitted = admitted(c_id)}))
            local class_content = {text = "from class"}
            local class_send = harness.value(c:call("inbox_send", {thread_id = b_thread, target_action_id = "action-b", sender_thread_id = c_thread,
                sender_action_id = "action-c", node_id = node_id, grant_epoch = 2, idempotency_key = harness.key(), message_id = "class-1",
                content = class_content, payload_digest = assert(sends.payload_digest({message_id = "class-1", content = class_content}))}))
            test.eq(class_send.inbox_sequence, 2)
        end)
        test.it("offers one ordered item under a carrier epoch and redelivers its identity after a crash", function()
            local grants = {"bee:thread_create_policy", "bee:thread_lifecycle_policy", "bee:thread_carrier_policy", "bee.threads:inbox_send_test_policy"}
            local sender = harness.principal("push-sender", grants, WORKSPACE)
            local target = harness.principal("push-target", grants, WORKSPACE)
            local sender_thread = harness.thread(sender, "sender")
            local target_thread = harness.thread(target, "target")
            harness.value(sender:call("admit_action", {thread_id = sender_thread, idempotency_key = harness.key(), action_id = "sender", admitted = admitted("push-sender")}))
            harness.value(target:call("admit_action", {thread_id = target_thread, idempotency_key = harness.key(), action_id = "target", admitted = admitted("push-target")}))
            harness.value(target:call("prepare_attempt", {thread_id = target_thread, idempotency_key = harness.key(), action_id = "target", attempt_id = "target-attempt", prepared = harness.prepared()}))
            local first_epoch = harness.value(target:call("carrier_claim", {thread_id = target_thread, attempt_id = "target-attempt", idempotency_key = harness.key()})).carrier_epoch
            harness.value(target:call("inbox_accept", {thread_id = target_thread, action_id = "target", sender_id = "push-sender", allow = true,
                expected_epoch = 0, idempotency_key = harness.key()}))
            local native = system.node.id()
            local node_id = native and native ~= "" and native or "local"
            local sent: {{[string]: unknown}} = {}
            for index = 1, 2 do
                local content = {text = "item " .. tostring(index)}
                local id = "push-" .. tostring(index)
                sent[index] = harness.value(sender:call("inbox_send", {thread_id = target_thread, target_action_id = "target", sender_thread_id = sender_thread,
                    sender_action_id = "sender", node_id = node_id, grant_epoch = 1, idempotency_key = harness.key(), message_id = id,
                    content = content, payload_digest = assert(sends.payload_digest({message_id = id, content = content}))}))
            end
            local offer = {thread_id = target_thread, action_id = "target", attempt_id = "target-attempt", carrier_epoch = first_epoch}
            local no_carrier = harness.principal("push-target", {"bee:thread_create_policy", "bee:thread_lifecycle_policy"}, WORKSPACE)
            test.eq(harness.code(no_carrier:call("inbox_offer", offer)), "DENIED")
            test.eq(harness.code(sender:call("inbox_offer", offer)), "DENIED")
            local first = harness.value(target:call("inbox_offer", offer))
            test.eq(first.record_id, sent[1].record_id)
            test.eq(first.inbox_sequence, 1)
            test.eq(first.state, "offered")
            test.eq(first.dispatch, true)
            test.eq(harness.value(target:call("inbox_offer", offer)).dispatch, false)
            local second_epoch = harness.value(target:call("carrier_claim", {thread_id = target_thread, attempt_id = "target-attempt", idempotency_key = harness.key()})).carrier_epoch
            test.eq(harness.code(target:call("inbox_transport", {thread_id = target_thread, action_id = "target", attempt_id = "target-attempt",
                carrier_epoch = first_epoch, inbox_sequence = 1, record_id = first.record_id})), "CONFLICT")
            offer.carrier_epoch = second_epoch
            local redelivered = harness.value(target:call("inbox_offer", offer))
            test.eq(redelivered.record_id, first.record_id)
            test.eq(redelivered.payload_digest, first.payload_digest)
            test.eq(redelivered.dispatch, true)
            test.eq(redelivered.offer_count, 2)
            local accepted = harness.value(target:call("inbox_transport", {thread_id = target_thread, action_id = "target", attempt_id = "target-attempt",
                carrier_epoch = second_epoch, inbox_sequence = 1, record_id = first.record_id}))
            test.eq(accepted.state, "transport_accepted")
            test.eq(harness.code(target:call("inbox_transport", {thread_id = target_thread, action_id = "target", attempt_id = "target-attempt",
                carrier_epoch = second_epoch, inbox_sequence = 1, record_id = sent[2].record_id})), "CONFLICT")
            test.eq(harness.value(target:call("inbox_offer", offer)).inbox_sequence, 1)
            harness.value(target:call("inbox_ack", {thread_id = target_thread, action_id = "target", inbox_sequence = 1, idempotency_key = harness.key()}))
            local next_item = harness.value(target:call("inbox_offer", offer))
            test.eq(next_item.record_id, sent[2].record_id)
            test.eq(next_item.inbox_sequence, 2)
        end)
    end)
end
return test.run_cases(define_tests)
