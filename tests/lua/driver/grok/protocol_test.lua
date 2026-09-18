-- MIT. Grok protocol tests: NDJSON streaming-json normalization,
-- auto-started turn/session state, thought reasoning, text accumulation,
-- tool calls and updates, terminal end events, and EOF fallback.
local test = require("test")
local protocol = require("protocol")
local normalize = require("normalize")

local function define_tests()
    test.describe("Grok protocol", function()
        test.it("initializes state and auto-starts session and turn on first envelope", function()
            local state = protocol.new(false)
            test.is_false(state.started)
            test.is_false(state.resumed)
            test.is_nil(state.terminal)
            test.is_nil(state.answer)

            local step1 = protocol.normalize(state, 1, {
                type = "thought",
                data = "Thinking deeply...",
                sessionId = "session-abc",
            })
            test.is_true(state.started)
            test.eq(state.session_id, "session-abc")
            test.eq(#step1.observations, 3)

            -- First observation: session.state
            test.eq(step1.observations[1].type, "session.state")
            local sess_data = step1.observations[1].data :: {[string]: unknown}
            test.eq(sess_data.state, "started")
            test.eq(sess_data.resume_ref, "session-abc")

            -- Second observation: turn.signal started
            test.eq(step1.observations[2].type, "turn.signal")
            local turn_data = step1.observations[2].data :: {[string]: unknown}
            test.eq(turn_data.phase, "started")

            -- Third observation: text reasoning
            test.eq(step1.observations[3].type, "text")
            local text_data = step1.observations[3].data :: {[string]: unknown}
            test.eq(text_data.channel, "reasoning_summary")
            test.eq(text_data.segment_id, "reasoning")
            test.eq(text_data.operation, "append")
            test.eq(text_data.text, "Thinking deeply...")

            -- Subsequent envelope does not re-emit session start or turn start
            local step2 = protocol.normalize(state, 2, {type = "thought", data = "Still thinking"})
            test.eq(#step2.observations, 1)
            test.eq(step2.observations[1].type, "text")
        end)

        test.it("handles resumed session state phase", function()
            local state = protocol.new(true)
            test.is_true(state.resumed)

            local step = protocol.normalize(state, 1, {type = "text", data = "hello", sessionId = "sess-2"})
            test.is_true(state.started)
            local sess_data = step.observations[1].data :: {[string]: unknown}
            test.eq(sess_data.state, "resumed")
        end)

        test.it("accumulates text into state.answer across multiple chunks", function()
            local state = protocol.new(false)
            protocol.normalize(state, 1, {type = "text", data = "Part 1. "})
            protocol.normalize(state, 2, {type = "text", data = "Part 2. "})
            protocol.normalize(state, 3, {type = "text", data = "Part 3."})
            test.eq(state.answer, "Part 1. Part 2. Part 3.")
        end)

        test.it("normalizes tool_call and tool_call_update events", function()
            local state = protocol.new(false)
            local call_step = protocol.normalize(state, 1, {
                type = "tool_call",
                toolCallId = "call-001",
                toolName = "bee__read_file",
                rawInput = {path = "config.json"},
            })
            -- First envelope auto-starts (3 observations total)
            local tool_call = call_step.observations[3]
            test.eq(tool_call.type, "tool.call")
            local call_data = tool_call.data :: {[string]: unknown}
            test.eq(call_data.call_id, "call-001")
            test.eq(call_data.tool_name, "bee__read_file")
            local input_content = call_data.input :: {[string]: unknown}
            test.is_true((input_content.text :: string):find("config.json", 1, true) ~= nil)

            -- Successful tool result
            local update_ok = protocol.normalize(state, 2, {
                type = "tool_call_update",
                toolCallId = "call-001",
                status = "completed",
                rawOutput = "content of config",
            })
            test.eq(#update_ok.observations, 1)
            local res_ok = update_ok.observations[1]
            test.eq(res_ok.type, "tool.result")
            local ok_data = res_ok.data :: {[string]: unknown}
            test.eq(ok_data.call_id, "call-001")
            test.eq(ok_data.outcome, "succeeded")
            local ok_content = ok_data.output :: {[string]: unknown}
            test.eq(ok_content.text, "content of config")
            test.is_nil(ok_data.error)

            -- Failed tool result
            local update_fail = protocol.normalize(state, 3, {
                type = "tool_call_update",
                toolCallId = "call-002",
                status = "failed",
                rawOutput = "permission denied",
            })
            test.eq(#update_fail.observations, 1)
            local res_fail = update_fail.observations[1]
            test.eq(res_fail.type, "tool.result")
            local fail_data = res_fail.data :: {[string]: unknown}
            test.eq(fail_data.outcome, "failed")
            test.not_nil(fail_data.error)
            local fault = fail_data.error :: {[string]: unknown}
            test.eq(fault.code, "tool_error")
            test.eq(fault.message, "permission denied")

            -- The protocol also uses update frames while work is in progress.
            local update_running = protocol.normalize(state, 4, {
                type = "tool_call_update",
                toolCallId = "call-003",
                status = "running",
                rawOutput = "still working",
            })
            test.eq(#update_running.observations, 1)
            test.eq(update_running.observations[1].type, "extension")
            local running_data = update_running.observations[1].data :: {[string]: unknown}
            test.eq(running_data.event_name, "grok.tool_call_update")
        end)

        test.it("normalizes usage, available_commands, plan, and error envelopes", function()
            local state = protocol.new(false)
            -- Usage
            protocol.normalize(state, 1, {
                type = "usage",
                input_tokens = 250,
                output_tokens = 100,
                cache_read_input_tokens = 50,
            })
            test.not_nil(state.usage)
            test.eq(state.usage.input_tokens, 250)
            test.eq(state.usage.output_tokens, 100)
            test.eq(state.usage.cached_tokens, 50)

            -- Commands extension
            local cmd_step = protocol.normalize(state, 2, {
                type = "available_commands",
                commands = {"cmd1", "cmd2"},
            })
            test.eq(#cmd_step.observations, 1)
            test.eq(cmd_step.observations[1].type, "extension")
            local cmd_data = cmd_step.observations[1].data :: {[string]: unknown}
            test.eq(cmd_data.event_name, "grok.available_commands")

            -- Plan extension
            local plan_step = protocol.normalize(state, 3, {
                type = "plan",
                steps = {{id = 1, desc = "step 1"}},
            })
            test.eq(#plan_step.observations, 1)
            test.eq(plan_step.observations[1].type, "extension")
            local plan_data = plan_step.observations[1].data :: {[string]: unknown}
            test.eq(plan_data.event_name, "grok.plan")

            -- Error notice
            local err_step = protocol.normalize(state, 4, {
                type = "error",
                message = "Rate limit reached. Try again later.",
            })
            test.eq(#err_step.observations, 1)
            test.eq(err_step.observations[1].type, "notice")
            local err_data = err_step.observations[1].data :: {[string]: unknown}
            test.eq(err_data.code, "provider_error")
            local notice_content = err_data.content :: {[string]: unknown}
            test.eq(notice_content.text, "Rate limit reached. Try again later.")
        end)

        test.it("terminates turn on end event with succeeded outcome and usage", function()
            local state = protocol.new(false)
            protocol.normalize(state, 1, {type = "text", data = "The final answer."})
            local end_step = protocol.normalize(state, 2, {
                type = "end",
                stopReason = "end_turn",
                sessionId = "sess-final",
                usage = {input_tokens = 500, output_tokens = 200},
            })
            test.not_nil(end_step.terminal)
            test.eq(end_step.terminal.outcome, "succeeded")
            test.eq(end_step.terminal.answer, "The final answer.")
            test.eq(end_step.terminal.resume_ref, "sess-final")
            test.eq(end_step.terminal.usage.input_tokens, 500)
            test.eq(end_step.terminal.usage.output_tokens, 200)
            test.is_nil(end_step.terminal.error)

            -- Verify turn ended observation was emitted
            local turn_obs = end_step.observations[1]
            test.eq(turn_obs.type, "turn.signal")
            local turn_data = turn_obs.data :: {[string]: unknown}
            test.eq(turn_data.phase, "ended")
            test.eq(turn_data.reported_outcome, "succeeded")

            -- After terminal, envelope emits warning notice
            local after_step = protocol.normalize(state, 3, {type = "text", data = "extra"})
            test.is_nil(after_step.terminal)
            test.eq(#after_step.observations, 1)
            test.eq(after_step.observations[1].type, "notice")
            local after_data = after_step.observations[1].data :: {[string]: unknown}
            test.eq(after_data.code, "after_terminal")

            -- Finish after terminal is a quiet no-op
            local quiet = protocol.finish(state, 4)
            test.is_nil(quiet.terminal)
            test.eq(#quiet.observations, 0)
        end)

        test.it("handles end event with cancelled and failed outcomes", function()
            -- Cancelled
            local state_cancel = protocol.new(false)
            local cancel_step = protocol.normalize(state_cancel, 1, {
                type = "end",
                stopReason = "cancelled",
                sessionId = "sess-c",
            })
            test.not_nil(cancel_step.terminal)
            test.eq(cancel_step.terminal.outcome, "cancelled")

            -- Failed with error status
            local state_fail = protocol.new(false)
            local fail_step = protocol.normalize(state_fail, 1, {
                type = "end",
                status = "error",
                message = "Model context length exceeded",
                sessionId = "sess-f",
            })
            test.not_nil(fail_step.terminal)
            test.eq(fail_step.terminal.outcome, "failed")
            test.not_nil(fail_step.terminal.error)
            test.eq(fail_step.terminal.error.code, "turn_failed")
            test.eq(fail_step.terminal.error.message, "Model context length exceeded")
        end)

        test.it("handles finish on unterminated stream as uncertain", function()
            local state = protocol.new(false)
            protocol.normalize(state, 1, {type = "text", data = "partial stream", sessionId = "sess-eof"})
            local finish_step = protocol.finish(state, 2)
            test.not_nil(finish_step.terminal)
            test.eq(finish_step.terminal.outcome, "uncertain")
            test.eq(finish_step.terminal.answer, "partial stream")
            test.eq(finish_step.terminal.resume_ref, "sess-eof")
            test.not_nil(finish_step.terminal.error)
            test.eq(finish_step.terminal.error.code, "stream_ended")

            local turn_obs = finish_step.observations[1]
            test.eq(turn_obs.type, "turn.signal")
            local turn_data = turn_obs.data :: {[string]: unknown}
            test.eq(turn_data.phase, "ended")
            test.eq(turn_data.reported_outcome, "uncertain")
        end)

        test.it("does not accept malformed end events as successful", function()
            local state = protocol.new(false)
            local step = protocol.normalize(state, 1, {type = "end", sessionId = "sess-blank"})
            test.not_nil(step.terminal)
            test.eq(step.terminal.outcome, "uncertain")
            test.not_nil(step.terminal.error)
            test.eq(step.terminal.error.code, "unrecognized_stop_reason")
        end)

        test.it("keeps the first session identity and bounds retained state", function()
            local state = protocol.new(false)
            protocol.normalize(state, 1, {type = "text", data = "first", sessionId = "sess-original"})
            local changed = protocol.normalize(state, 2, {type = "text", data = " second", sessionId = "sess-other"})
            test.eq(state.session_id, "sess-original")
            test.eq(changed.observations[1].type, "notice")
            local notice = changed.observations[1].data :: {[string]: unknown}
            test.eq(notice.code, "session_mismatch")

            protocol.normalize(state, 3, {type = "text", data = string.rep("x", protocol.MAX_ANSWER_BYTES)})
            test.is_true(state.answer_truncated)
            test.is_nil(state.answer)
            local done = protocol.normalize(state, 4, {type = "end", stopReason = "end_turn", sessionId = "sess-original"})
            test.eq(done.terminal.resume_ref, "sess-original")
            test.is_nil(done.terminal.answer)
        end)

        test.it("rejects untrusted persisted state instead of casting it", function()
            local reply = normalize.handle({
                index = 1,
                state = {started = true, resumed = false, answer_truncated = false, tools = {unbounded = "state"}},
                eof = true,
            })
            test.is_false(reply.ok)
            test.eq(reply.error, "state: unknown field tools")

            local overlong = normalize.handle({
                index = 1,
                state = {started = false, resumed = false, answer_truncated = false, answer = string.rep("x", protocol.MAX_ANSWER_BYTES + 1)},
                eof = true,
            })
            test.is_false(overlong.ok)
            test.eq(overlong.error, "state.answer exceeds the retained answer bound")

            local bad_usage = normalize.handle({
                index = 1,
                state = {started = false, resumed = false, answer_truncated = false, usage = {input_tokens = 1, output_tokens = -1}},
                eof = true,
            })
            test.is_false(bad_usage.ok)
            test.eq(bad_usage.error, "state.usage.output_tokens is not a nonnegative integer")
        end)

        test.it("requires boolean eof and resumed request flags", function()
            local bad_eof = normalize.handle({index = 1, envelope = {type = "text", data = "x"}, eof = "true"})
            test.is_false(bad_eof.ok)
            test.eq(bad_eof.error, "eof must be a boolean")
            local bad_resumed = normalize.handle({index = 1, envelope = {type = "text", data = "x"}, resumed = 1})
            test.is_false(bad_resumed.ok)
            test.eq(bad_resumed.error, "resumed must be a boolean")
        end)

        test.it("integrates through normalize method handler", function()
            local res1 = normalize.handle({
                index = 0,
                envelope = {type = "text", data = "hello via handle"},
                resumed = false,
            })
            test.is_true(res1.ok)
            test.not_nil(res1.state)
            test.is_nil(res1.terminal)

            -- Send EOF via handle
            local res2 = normalize.handle({
                index = 1,
                state = res1.state,
                eof = true,
            })
            test.is_true(res2.ok)
            test.not_nil(res2.terminal)
            test.eq(res2.terminal.outcome, "uncertain")
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
