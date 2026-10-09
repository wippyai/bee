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
