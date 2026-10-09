local test = require("test")
local harness = require("harness")
local bounds = require("bounds")
local function define_tests()
    test.describe("Per-turn usage", function()
        local owner = harness.session_owner(string.rep("d", 32))
        local function completed(events: {{[string]: unknown}}, reported: unknown?): {[string]: unknown}
            local session = harness.value(owner:call("session_create", {operation_key = harness.key()})).session
            local workspace = string.rep("d", 32)
            local described = harness.value(owner:call("session_describe", {session = session}))
            local carrier = harness.principal("sessions-owner", harness.ALL, workspace)
            local admitted = harness.admitted(); admitted.principal_id = assert(bounds.id(session))
            harness.value(carrier:call("admit_action", {thread_id = described.thread_ref, action_id = session, admitted = admitted, idempotency_key = harness.key()}))
            harness.value(owner:call("work_send", {session = session, input = "Count once", operation_key = harness.key()}))
            local reserved = harness.value(owner:call("turn_reserve", {session = session, operation_key = harness.key()}))
            local pulled = harness.value(owner:call("turn_pull", {turn = reserved.turn, claim = reserved.claim}))
            harness.value(owner:call("turn_accept", {turn = reserved.turn, claim = reserved.claim, input_digest = pulled.input_digest, checkpoint = {}, operation_key = harness.key()}))
            for index, data in ipairs(events) do
                harness.value(owner:call("turn_observation", {turn = reserved.turn, claim = reserved.claim, operation_key = harness.key(),
                    observation = {type = data.type, event_key = harness.key(), data = data}}))
                for _, source in ipairs({"hook", "stream"}) do
                    harness.value(carrier:call("record", {thread_id = described.thread_ref, idempotency_key = harness.key(), kind = "observation", source = source,
                        context = {action_id = session}, body = {type = data.type, event_key = "native-" .. tostring(index), data = data}}))
                end
            end
            harness.value(owner:call("work_settle", {turn = reserved.turn, claim = reserved.claim, operation_key = harness.key(),
                result = {state = "succeeded", schema = "bee:Text@1", value = {text = "Done"}, usage = reported}}))
            local feed = harness.value(owner:call("feed_read", {session = session, after_sequence = 0, limit = 64}))
            for _, row in ipairs(harness.objects(feed.events, 128)) do
                if row.kind == "work.settled" then return assert(bounds.object(assert(bounds.object(row.data)).usage)) end
            end
            error("missing completion")
        end
        test.it("binds late native observations to their original turn across two turns in one session", function()
            local session = harness.value(owner:call("session_create", {operation_key = harness.key()})).session
            local thread = harness.value(owner:call("session_describe", {session = session})).thread_ref
            local carrier = harness.principal("sessions-owner", harness.ALL, string.rep("d", 32))
            local admitted = harness.admitted(); admitted.principal_id = assert(bounds.id(session))
            harness.value(carrier:call("admit_action", {thread_id = thread, action_id = session, admitted = admitted, idempotency_key = harness.key()}))
            local attempt = harness.key()
            harness.value(carrier:call("prepare_attempt", {thread_id = thread, action_id = session, attempt_id = attempt, prepared = harness.prepared(), idempotency_key = harness.key()}))
            harness.value(carrier:call("start_attempt", {thread_id = thread, action_id = session, attempt_id = attempt,
                started = {execution_kind = "process", execution_ref = "usage-fixture", owner_epoch = 1}, idempotency_key = harness.key()}))
            local function begin(): {[string]: unknown}
                harness.value(owner:call("work_send", {session = session, input = "Count", operation_key = harness.key()}))
                local turn = harness.value(owner:call("turn_reserve", {session = session, operation_key = harness.key()}))
                local pulled = harness.value(owner:call("turn_pull", {turn = turn.turn, claim = turn.claim}))
                harness.value(owner:call("turn_accept", {turn = turn.turn, claim = turn.claim, input_digest = pulled.input_digest, checkpoint = {}, operation_key = harness.key()}))
                harness.value(carrier:call("request_turn", {thread_id = thread, action_id = session, attempt_id = attempt, turn_id = turn.turn,
                    turn = {input_message_ids = {}, input = {text = "Count"}, delivery_ids = {}}, idempotency_key = harness.key()}))
                return turn
            end
            local function native(turn: unknown, tokens: integer, call: string)
                for _, source in ipairs({"hook", "stream"}) do
                    for _, data in ipairs({{type = "turn.signal", phase = "ended", usage = {input_tokens = tokens}},
                        {type = "tool.call", call_id = call, tool_name = "Read", input = {text = "x"}}}) do
                        harness.value(carrier:call("record", {thread_id = thread, idempotency_key = harness.key(), kind = "observation", source = source,
                            context = {action_id = session, attempt_id = attempt, turn_id = turn}, body = {type = data.type, event_key = harness.key(), data = data}}))
                    end
                end
            end
            local function finish(turn: {[string]: unknown})
                harness.value(carrier:call("end_turn", {thread_id = thread, action_id = session, attempt_id = attempt, turn_id = turn.turn,
                    turn_end = {outcome = "succeeded", answer_message_ids = {}, evidence_refs = {}}, idempotency_key = harness.key()}))
                harness.value(owner:call("work_settle", {turn = turn.turn, claim = turn.claim, operation_key = harness.key(),
                    result = {state = "succeeded", schema = "bee:Text@1", value = {text = "Done"}}}))
            end
            local a = begin(); native(a.turn, 100, "call-a"); finish(a)
            local b = begin(); native(a.turn, 100, "call-a"); native(b.turn, 7, "call-b"); finish(b)
            local feed = harness.value(owner:call("feed_read", {session = session, after_sequence = 0, limit = 64}))
            local totals: {{[string]: unknown}} = {}
            for _, event in ipairs(harness.objects(feed.events, 128)) do
                if event.kind == "work.settled" then totals[#totals + 1] = assert(bounds.object(assert(bounds.object(event.data)).usage)) end
            end
            test.eq(#totals, 2)
            test.eq(totals[1].input_tokens, 100)
            test.eq(totals[1].tool_calls, 1)
            test.eq(totals[2].input_tokens, 7)
            test.eq(totals[2].tool_calls, 1)
            test.is_nil(totals[2].output_tokens)
        end)
        test.it("keeps unknown counters absent and distinguishes reported zero", function()
            local unknown = completed({})
            test.eq(unknown.coverage, "unknown")
            test.is_nil(unknown.input_tokens)
            test.is_nil(unknown.output_tokens)
            test.is_nil(unknown.cached_tokens)
            test.is_nil(unknown.tool_calls)
            local zero = completed({}, {input_tokens = 0, output_tokens = 0})
            test.eq(zero.input_tokens, 0)
            test.eq(zero.output_tokens, 0)
            test.is_nil(zero.cached_tokens)
            test.eq(zero.coverage, "partial")
        end)
        test.it("deduplicates hook and stream summaries and tool occurrence identities", function()
            local usage = completed({
                {type = "turn.signal", phase = "ended", usage = {input_tokens = 12, output_tokens = 5}},
                {type = "turn.signal", phase = "ended", usage = {input_tokens = 12, output_tokens = 5, cached_tokens = 3}},
                {type = "tool.call", call_id = "same-native-call", tool_name = "Read", input = {text = "x"}},
                {type = "tool.call", call_id = "same-native-call", tool_name = "Read", input = {text = "x"}},
                {type = "tool.call", call_id = "second-call", tool_name = "Read", input = {text = "y"}},
            }, {input_tokens = 12, output_tokens = 5})
            test.eq(usage.input_tokens, 12)
            test.eq(usage.output_tokens, 5)
            test.eq(usage.cached_tokens, 3)
            test.eq(usage.tool_calls, 2)
            test.eq(usage.coverage, "partial")
            local next_turn = completed({})
            test.is_nil(next_turn.input_tokens)
            test.is_nil(next_turn.tool_calls)
        end)
    end)
end
return test.run_cases(define_tests)
