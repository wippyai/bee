-- MIT. Claude and Codex normalizers against captured fixtures: every
-- observation decodes, answers come only from terminal envelopes, tool
-- failures and denials are evidence, and a truncated stream is uncertain.
local test = require("test")
local fs = require("fs")
local json = require("json")
local funcs = require("funcs")
local stream_json = require("stream_json")
local claude = require("claude")
local codex = require("codex")
local muse = require("muse")
local claude_launch = require("claude_launch")
local codex_launch = require("codex_launch")
local muse_launch = require("muse_launch")
local observation = require("observation")
local quote = require("quote")
type Terminal = {outcome: string, answer: string?, resume_ref: string?, usage: {[string]: unknown}?, error: {code: string, message: string, retryable: boolean}?}
type Run = {types: {string}, observations: {{[string]: unknown}}, terminal: Terminal?, problems: integer}
local function fixture(path: string): string
    local volume, err = fs.get("bee.driver:fixtures")
    if not volume then error("fixtures: " .. tostring(err)) end
    local content, read_error = volume:readfile(path)
    if not content then error(path .. ": " .. tostring(read_error)) end
    return content
end
-- Feeds a fixture in odd-sized chunks through the transport and the
-- normalizer; optionally stops before the last frame.
local function run(normalizer: any, path: string, chunk_size: integer, drop_last: boolean): Run
    local content = fixture(path)
    if drop_last then
        local cut = content:sub(1, -2)
        local last = cut:find("\n[^\n]*$")
        content = cut:sub(1, last or #cut)
    end
    local decoder = stream_json.new()
    local state = normalizer.new(false)
    local result: Run = {types = {}, observations = {}, terminal = nil, problems = 0}
    local offset = 1
    while offset <= #content do
        local envelopes, problems = stream_json.feed(decoder, content:sub(offset, offset + chunk_size - 1))
        result.problems = result.problems + #problems
        for _, envelope in ipairs(envelopes) do
            local step = normalizer.normalize(state, envelope.index, envelope.value)
            for _, item in ipairs(step.observations) do
                local decoded, err = observation.decode(item)
                if not decoded then error(path .. " " .. tostring(item.type) .. ": " .. tostring(err)) end
                result.types[#result.types + 1] = tostring(item.type) .. ":" .. tostring(item.data.state or item.data.phase or item.data.outcome or item.data.level or item.data.channel or "")
                result.observations[#result.observations + 1] = item
            end
            if step.terminal then result.terminal = step.terminal end
        end
        offset = offset + chunk_size
    end
    local tail = stream_json.finish(decoder)
    if tail then result.problems = result.problems + 1 end
    local final = normalizer.finish(state, decoder.index + 1)
    for _, item in ipairs(final.observations) do
        local decoded, err = observation.decode(item)
        if not decoded then error(path .. " eof: " .. tostring(err)) end
        result.types[#result.types + 1] = tostring(item.type) .. ":" .. tostring(item.data.phase or "")
    end
    if final.terminal then result.terminal = final.terminal end
    return result
end
local function has(list: {string}, item: string): boolean
    for _, candidate in ipairs(list) do if candidate == item then return true end end
    return false
end
local function define_tests()
    test.describe("Claude stream-json normalization", function()
        test.it("extracts the answer from the result and streams deltas as answer text", function()
            for _, size in ipairs({7, 64, 4096}) do
                local plain = run(claude, "/claude/stream-json-2/plain.jsonl", size, false)
                test.eq(plain.problems, 0)
                if not plain.terminal then error("no terminal") end
                test.eq(plain.terminal.outcome, "succeeded")
                test.eq(plain.terminal.answer, "pong")
                test.not_nil(plain.terminal.resume_ref)
                test.is_true(has(plain.types, "session.state:started"))
                test.is_true(has(plain.types, "text:answer"))
                test.is_true(has(plain.types, "turn.signal:ended"))
                test.is_true(plain.terminal.usage ~= nil and plain.terminal.usage.input_tokens ~= nil)
            end
        end)
        test.it("records tool calls, results and failures as evidence", function()
            local tool = run(claude, "/claude/stream-json-2/tool.jsonl", 100, false)
            test.is_true(has(tool.types, "tool.call:"))
            test.is_true(has(tool.types, "tool.result:succeeded"))
            test.eq(tool.terminal and tool.terminal.answer, "hive fixture")
            local failure = run(claude, "/claude/stream-json-2/tool_failure.jsonl", 100, false)
            test.is_true(has(failure.types, "tool.result:failed"))
            test.eq(failure.terminal and failure.terminal.outcome, "succeeded")
            test.eq(failure.terminal and failure.terminal.answer, "failed")
        end)
        test.it("keeps denials and api errors honest", function()
            local denied = run(claude, "/claude/stream-json-2/permission_denied.jsonl", 100, false)
            test.is_true(has(denied.types, "notice:warning"))
            test.eq(denied.terminal and denied.terminal.outcome, "succeeded")
            local api = run(claude, "/claude/stream-json-2/api_error.jsonl", 100, false)
            if not api.terminal then error("no terminal") end
            test.eq(api.terminal.outcome, "failed")
            test.is_nil(api.terminal.answer)
            test.eq(api.terminal.error and api.terminal.error.code, "api_error")
            test.is_true(api.terminal.error ~= nil and api.terminal.error.retryable)
        end)
        test.it("reports a stream that ends before the result as uncertain", function()
            local cut = run(claude, "/claude/stream-json-2/plain.jsonl", 50, true)
            if not cut.terminal then error("no terminal") end
            test.eq(cut.terminal.outcome, "uncertain")
            test.is_nil(cut.terminal.answer)
            test.eq(cut.terminal.error and cut.terminal.error.code, "stream_ended")
            test.is_true(has(cut.types, "turn.signal:ended"))
        end)
        test.it("produces declarative launch specifications only", function()
            local request, err = claude_launch.decode({profile_id = "session", brief = "say hi", permission_mode = "dontAsk", max_turns = 2, model = "sonnet", effort = "xhigh"})
            if not request then error(tostring(err)) end
            local launch = claude_launch.specification(request)
            test.eq(launch.executable, "claude")
            test.eq(quote.line(launch.argv), "-p --output-format stream-json --verbose --include-partial-messages --permission-mode dontAsk --max-turns 2 --model sonnet --effort xhigh -- 'say hi'")
            local _, mode_error = claude_launch.decode({profile_id = "session", brief = "x", permission_mode = "bypassPermissions"})
            test.eq(mode_error, "permission_mode is not one Bee admits")
            local _, model_error = claude_launch.decode({profile_id = "session", brief = "x", model = "not a model"})
            test.eq(model_error, "model is not one bounded model identifier")
            local _, effort_error = claude_launch.decode({profile_id = "session", brief = "x", effort = "turbo"})
            test.eq(effort_error, "effort is not one Bee admits")
            local resumed = claude_launch.specification({profile_id = "session", brief = "next", permission_mode = "default", max_turns = 1, resume_ref = "sess-1", permission_exchange = false})
            test.eq(resumed.argv[#resumed.argv - 2], "sess-1")
            test.eq(resumed.argv[#resumed.argv - 1], "--")
            test.eq(resumed.argv[#resumed.argv], "next")
            local literal_request, literal_error = claude_launch.decode({profile_id = "batch", brief = "--version"})
            if not literal_request then error(tostring(literal_error)) end
            local literal = claude_launch.specification(literal_request)
            test.eq(literal.argv[#literal.argv - 1], "--")
            test.eq(literal.argv[#literal.argv], "--version")
            -- The exchange launch: the brief is the first stream-json line
            -- on stdin, canonically encoded, stdin stays open, and prompts
            -- route to the stdio prompt tool.
            local exchange, exchange_error = claude_launch.decode({profile_id = "batch", brief = "leave a \"marker\"", permission_mode = "default", max_turns = 3, permission_exchange = true})
            if not exchange then error(tostring(exchange_error)) end
            local interactive = claude_launch.specification(exchange)
            test.eq(quote.line(interactive.argv), "-p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --permission-mode default --max-turns 3 --permission-prompt-tool stdio --permission-prompts host")
            test.eq(interactive.stdin, '{"message":{"content":"leave a \\"marker\\"","role":"user"},"type":"user"}\n')
            test.is_nil(interactive.stdin_eof)
            test.eq(interactive.session_end, "stdin_close")
            test.is_nil(resumed.session_end)
            local _, flag_error = claude_launch.decode({profile_id = "batch", brief = "x", permission_exchange = "yes"})
            test.eq(flag_error, "permission_exchange must be a boolean")
            local reply, call_error = funcs.call("bee.driver.claude:dispatch", {profile_id = "session", brief = "next"})
            if call_error then error(tostring(call_error)) end
            test.is_false(reply.ok)
            test.eq(reply.error, "a dispatched turn needs resume_ref")
        end)
    end)
    test.describe("Native interactive launch specifications", function()
        test.it("opens native UIs without a prompt and preserves scoped flags on resume", function()
            local claude_request, claude_error = claude_launch.decode({profile_id = "window", brief = "", model = "sonnet", effort = "high"})
            if not claude_request then error(tostring(claude_error)) end
            local claude_window = claude_launch.specification(claude_request)
            test.eq(quote.line(claude_window.argv), "--permission-mode default --model sonnet --effort high")
            test.eq(claude_window.readiness, "terminal:attached")
            test.is_nil(claude_window.stdin); test.is_nil(claude_window.stdin_eof); test.is_nil(claude_window.session_end)
            local codex_request, codex_error = codex_launch.decode({profile_id = "window", brief = "", sandbox = "workspace-write"})
            if not codex_request then error(tostring(codex_error)) end
            local codex_window = codex_launch.specification(codex_request)
            test.eq(quote.line(codex_window.argv), "--sandbox workspace-write")
            test.eq(codex_window.readiness, "terminal:attached")
            test.is_nil(codex_window.stdin); test.is_nil(codex_window.stdin_eof)
            local resume, resume_error = codex_launch.decode({profile_id = "window", brief = "--help", sandbox = "read-only", resume_ref = "native-session", gateway_hooks = {"SessionStart"}})
            if not resume then error(tostring(resume_error)) end
            test.eq(quote.line(codex_launch.specification(resume).argv), "--sandbox read-only resume native-session -- --help")
            claude_request.brief = "--help"
            claude_request.resume_ref = "native-session"
            test.eq(quote.line(claude_launch.specification(claude_request).argv), "--permission-mode default --model sonnet --effort high -r native-session -- --help")
        end)
        test.it("refuses structured-only options for a native window and empty structured turns", function()
            local no_turns, turns_error = claude_launch.decode({profile_id = "window", brief = "hello", max_turns = 2})
            test.is_nil(no_turns); test.eq(turns_error, "max_turns is only supported for structured turns")
            local no_exchange, exchange_error = claude_launch.decode({profile_id = "window", brief = "hello", permission_exchange = true})
            test.is_nil(no_exchange); test.eq(exchange_error, "stdio permission exchange is only supported for structured turns")
            local empty_claude = claude_launch.decode({profile_id = "batch", brief = ""})
            local empty_codex = codex_launch.decode({profile_id = "batch", brief = ""})
            test.is_nil(empty_claude); test.is_nil(empty_codex)
        end)
    end)
    test.describe("Codex exec-json normalization", function()
        test.it("takes the answer from the last agent message and usage from turn.completed", function()
            local plain = run(codex, "/codex/exec-json-1/plain.jsonl", 33, false)
            if not plain.terminal then error("no terminal") end
            test.eq(plain.terminal.outcome, "succeeded")
            test.eq(plain.terminal.answer, "pong")
            test.eq(plain.terminal.usage and plain.terminal.usage.input_tokens, 12651)
            test.is_true(has(plain.types, "session.state:started"))
            local tool = run(codex, "/codex/exec-json-1/tool.jsonl", 100, false)
            test.is_true(has(tool.types, "notice:warning"))
            test.is_true(has(tool.types, "tool.call:"))
            test.is_true(has(tool.types, "tool.result:succeeded"))
            test.eq(tool.terminal and tool.terminal.answer, "hive fixture\n")
            local failure = run(codex, "/codex/exec-json-1/tool_failure.jsonl", 100, false)
            test.is_true(has(failure.types, "tool.result:failed"))
            test.eq(failure.terminal and failure.terminal.answer, "failed")
        end)
        test.it("reports a stream without turn.completed as uncertain and builds argv", function()
            local cut = run(codex, "/codex/exec-json-1/plain.jsonl", 20, true)
            test.eq(cut.terminal and cut.terminal.outcome, "uncertain")
            local request, err = codex_launch.decode({profile_id = "batch", brief = "hello", sandbox = "workspace-write"})
            if not request then error(tostring(err)) end
            local launch = codex_launch.specification(request)
            test.eq(launch.stdin, "hello")
            test.eq(quote.line(launch.argv), "exec --json --skip-git-repo-check --sandbox workspace-write -")
            local resumed = codex_launch.specification({profile_id = "batch", brief = "next", sandbox = "read-only", resume_ref = "sess-1", gateway_hooks = true})
            test.eq(quote.line(resumed.argv), "--sandbox read-only exec resume sess-1 --json --skip-git-repo-check -")
            local _, sandbox_error = codex_launch.decode({profile_id = "batch", brief = "x", sandbox = "danger-full-access"})
            test.eq(sandbox_error, "sandbox is not one Bee admits")
            local reply = funcs.call("bee.driver.codex.binding:normalize", {index = 1, envelope = {type = "thread.started", thread_id = "t1"}})
            test.is_true(reply.ok)
            test.eq(reply.state.thread_id, "t1")
            local done = funcs.call("bee.driver.codex.binding:normalize", {state = reply.state, index = 2, eof = true})
            test.eq(done.terminal.outcome, "uncertain")
        end)
    end)
    test.describe("Muse msp-exec normalization", function()
        test.it("accumulates answer deltas and reports the terminal run only", function()
            for _, size in ipairs({7, 64, 4096}) do
                local echo = run(muse, "/muse/msp-exec-1/echo.jsonl", size, false)
                test.eq(echo.problems, 0)
                if not echo.terminal then error("no terminal") end
                test.eq(echo.terminal.outcome, "succeeded")
                test.eq(echo.terminal.answer, "echo: say ok")
                test.eq(echo.terminal.resume_ref, "01a0ad3f-1bad-7bb1-9290-d73200470b9e")
                test.is_nil(echo.terminal.usage)
                test.is_true(has(echo.types, "session.state:started"))
                test.is_true(has(echo.types, "turn.signal:started"))
                test.is_true(has(echo.types, "text:answer"))
                test.is_true(has(echo.types, "turn.signal:ended"))
            end
        end)
        test.it("normalizes explicit tool calls and results without guessing lifecycle tasks", function()
            local state = muse.new(false)
            local call = muse.normalize(state, 1, {
                payload_type = "tool.call",
                stream = {id = "sess-tools"},
                payload = {call_id = "call-1", tool_name = "read_file", input = {path = "fixture.txt"}},
            })
            test.eq(#call.observations, 1)
            test.eq(call.observations[1].type, "tool.call")
            local call_data = call.observations[1].data :: {[string]: unknown}
            test.eq(call_data.call_id, "call-1")
            test.eq(call_data.tool_name, "read_file")
            local result = muse.normalize(state, 2, {
                payload_type = "tool.result",
                stream = {id = "sess-tools"},
                payload = {call_id = "call-1", correlation_facts = {outcome = "success", tool_name = "read_file"}, text = "line 1"},
            })
            test.eq(#result.observations, 1)
            test.eq(result.observations[1].type, "tool.result")
            local result_data = result.observations[1].data :: {[string]: unknown}
            test.eq(result_data.call_id, "call-1")
            test.eq(result_data.outcome, "succeeded")
            local failed = muse.normalize(state, 3, {
                payload_type = "tool.result",
                stream = {id = "sess-tools"},
                payload = {call_id = "call-2", outcome = "error", reason = "denied", text = "no"},
            })
            test.eq(failed.observations[1].type, "tool.result")
            local failed_data = failed.observations[1].data :: {[string]: unknown}
            test.eq(failed_data.outcome, "failed")
            test.eq((failed_data.error :: {[string]: unknown}).code, "tool_error")

            local lifecycle = muse.normalize(state, 4, {
                payload_type = "task.lifecycle.proposed",
                stream = {id = "sess-tools"},
                payload = {task_id = "task-1", event = {kind = "proposed", task_id = "task-1", task_kind = "tool.read_file"}},
            })
            test.eq(lifecycle.observations[1].type, "extension")
        end)
        test.it("keeps an untyped failed task opaque and fails the terminal run", function()
            local failed = run(muse, "/muse/msp-exec-1/failure.jsonl", 100, false)
            test.is_true(has(failed.types, "extension:"))
            test.is_false(has(failed.types, "tool.result:failed"))
            if not failed.terminal then error("no terminal") end
            test.eq(failed.terminal.outcome, "failed")
            test.is_nil(failed.terminal.answer)
            test.eq(failed.terminal.error and failed.terminal.error.code, "run_failed")
            test.is_false(failed.terminal.error and failed.terminal.error.retryable)
        end)
        test.it("warns on envelopes after the terminal and ends a cut stream uncertain", function()
            local after = run(muse, "/muse/msp-exec-1/after_terminal.jsonl", 100, false)
            if not after.terminal then error("no terminal") end
            test.eq(after.terminal.outcome, "succeeded")
            test.is_true(has(after.types, "notice:warning"))
            local cut = run(muse, "/muse/msp-exec-1/truncated.jsonl", 50, false)
            if not cut.terminal then error("no terminal") end
            test.eq(cut.terminal.outcome, "uncertain")
            test.is_nil(cut.terminal.answer)
            test.eq(cut.terminal.error and cut.terminal.error.code, "stream_ended")
            test.is_true(has(cut.types, "turn.signal:ended"))
        end)
        test.it("keeps startup and session identity honest", function()
            local before_fixture = run(muse, "/muse/msp-exec-1/terminal_before_start.jsonl", 7, false)
            test.eq(before_fixture.terminal and before_fixture.terminal.outcome, "uncertain")
            test.eq(before_fixture.terminal and before_fixture.terminal.error and before_fixture.terminal.error.code, "terminal_before_start")
            local unknown_fixture = run(muse, "/muse/msp-exec-1/unknown_terminal.jsonl", 7, false)
            test.eq(unknown_fixture.terminal and unknown_fixture.terminal.outcome, "uncertain")
            test.eq(unknown_fixture.terminal and unknown_fixture.terminal.error and unknown_fixture.terminal.error.code, "run_terminal_unknown")

            local before_start = muse.normalize(muse.new(false), 1, {
                payload_type = "run.terminal.completed",
                stream = {id = "sess-before-start"},
                payload = {terminal = "completed"},
            })
            if not before_start.terminal then error("no terminal-before-start result") end
            test.eq(before_start.terminal.outcome, "uncertain")
            test.eq(before_start.terminal.error and before_start.terminal.error.code, "terminal_before_start")

            local failed_state = muse.new(false)
            muse.normalize(failed_state, 1, {payload_type = "runtime.command.accepted", stream = {id = "sess-failed"}, payload = {}})
            muse.normalize(failed_state, 2, {payload_type = "run.lifecycle.started", stream = {id = "sess-failed"}, payload = {}})
            local failed = muse.normalize(failed_state, 3, {
                payload_type = "run.terminal.completed",
                stream = {id = "sess-failed"},
                payload = {terminal = "failed", reason = "provider failed"},
            })
            if not failed.terminal then error("no failed terminal") end
            test.eq(failed.terminal.outcome, "failed")
            test.eq(failed.terminal.error and failed.terminal.error.code, "run_failed")

            local unknown_state = muse.new(false)
            muse.normalize(unknown_state, 1, {payload_type = "runtime.command.accepted", stream = {id = "sess-unknown"}, payload = {}})
            muse.normalize(unknown_state, 2, {payload_type = "run.lifecycle.started", stream = {id = "sess-unknown"}, payload = {}})
            local unknown = muse.normalize(unknown_state, 3, {
                payload_type = "run.terminal.completed",
                stream = {id = "sess-unknown"},
                payload = {terminal = "new-value"},
            })
            if not unknown.terminal then error("no unknown terminal") end
            test.eq(unknown.terminal.outcome, "uncertain")
            test.eq(unknown.terminal.error and unknown.terminal.error.code, "run_terminal_unknown")

            local identity_state = muse.new(false)
            muse.normalize(identity_state, 1, {payload_type = "runtime.command.accepted", stream = {id = "sess-original"}, payload = {}})
            local changed = muse.normalize(identity_state, 2, {payload_type = "run.lifecycle.started", stream = {id = "sess-other"}, payload = {}})
            test.eq(identity_state.session_id, "sess-original")
            local mismatch = changed.observations[1].data :: {[string]: unknown}
            test.eq(mismatch.code, "session_mismatch")
        end)
        test.it("bounds retained answers and rejects untrusted persisted state", function()
            local state = muse.new(false)
            muse.normalize(state, 1, {payload_type = "runtime.command.accepted", stream = {id = "sess-bounded"}, payload = {}})
            muse.normalize(state, 2, {payload_type = "run.lifecycle.started", stream = {id = "sess-bounded"}, payload = {}})
            muse.normalize(state, 3, {payload_type = "run.output.delta", stream = {id = "sess-bounded"}, payload = {text = "prefix"}})
            local oversized = muse.normalize(state, 4, {payload_type = "run.output.delta", stream = {id = "sess-bounded"}, payload = {text = string.rep("x", muse.MAX_ANSWER_BYTES)}})
            test.is_true(state.answer_truncated)
            test.is_nil(state.answer)
            local saw_bound = false
            for _, item in ipairs(oversized.observations) do
                local data = item.data :: {[string]: unknown}
                if data.code == "answer_truncated" then saw_bound = true end
            end
            test.is_true(saw_bound)
            local done = muse.normalize(state, 5, {payload_type = "run.terminal.completed", stream = {id = "sess-bounded"}, payload = {terminal = "completed"}})
            test.is_nil(done.terminal and done.terminal.answer)

            local unknown = funcs.call("bee.driver.muse:normalize", {index = 1, state = {
                resumed = false, command_accepted = false, run_started = false, answer_truncated = false,
                unknown = true,
            }, eof = true})
            test.is_false(unknown.ok)
            test.eq(unknown.error, "state: unknown field unknown")
            local overlong = funcs.call("bee.driver.muse:normalize", {index = 1, state = {
                resumed = false, command_accepted = false, run_started = false, answer_truncated = false,
                answer = string.rep("x", muse.MAX_ANSWER_BYTES + 1),
            }, eof = true})
            test.is_false(overlong.ok)
            test.eq(overlong.error, "state.answer exceeds the retained answer bound")
        end)
        test.it("produces declarative launch specifications only", function()
            local request, err = muse_launch.decode({profile_id = "batch", brief = "say ok"})
            if not request then error(tostring(err)) end
            local launch = muse_launch.specification(request)
            test.eq(launch.executable, "muse")
            test.eq(quote.line(launch.argv), "exec --json --approval-mode on-request -- 'say ok'")
            test.eq(launch.readiness, "protocol:runtime.command.accepted")
            test.is_nil(launch.stdin)
            local full, full_error = muse_launch.decode({profile_id = "batch", brief = "say ok", approval_mode = "never",
                model = "muse-spark-1.3", effort = "high", max_steps = 4})
            if not full then error(tostring(full_error)) end
            test.eq(quote.line(muse_launch.specification(full).argv),
                "exec --json --approval-mode never --model muse-spark-1.3 --reasoning-effort high --max-model-steps 4 -- 'say ok'")
            local resumed, resumed_error = muse_launch.decode({profile_id = "batch", brief = "next", resume_ref = "01a0ad3f-1bad-7bb1-9290-d73200470b9e"})
            if not resumed then error(tostring(resumed_error)) end
            test.eq(quote.line(muse_launch.specification(resumed).argv),
                "exec --json --approval-mode on-request --session-id 01a0ad3f-1bad-7bb1-9290-d73200470b9e -- next")
            local _, mode_error = muse_launch.decode({profile_id = "batch", brief = "x", approval_mode = "bypass"})
            test.eq(mode_error, "approval_mode is not one Bee admits")
            local _, effort_error = muse_launch.decode({profile_id = "batch", brief = "x", effort = "turbo"})
            test.eq(effort_error, "effort is not one Bee admits")
            -- Bee keeps one shared effort vocabulary across drivers; the
            -- executable-only values never pass through.
            for _, exotic in ipairs({"ultra", "minimal", "none"}) do
                local _, exotic_error = muse_launch.decode({profile_id = "batch", brief = "x", effort = exotic})
                test.eq(exotic_error, "effort is not one Bee admits")
            end
            local _, steps_error = muse_launch.decode({profile_id = "batch", brief = "x", max_steps = 0})
            test.eq(steps_error, "max_steps must be between 1 and 32")
            local _, model_error = muse_launch.decode({profile_id = "batch", brief = "x", model = "not a model"})
            test.eq(model_error, "model is not one bounded model identifier")
            local window, window_error = muse_launch.decode({profile_id = "window", brief = ""})
            if not window then error(tostring(window_error)) end
            local native = muse_launch.specification(window)
            test.eq(#native.argv, 0)
            test.eq(native.readiness, "terminal:attached")
            local prompted, prompted_error = muse_launch.decode({profile_id = "window", brief = "--help"})
            if not prompted then error(tostring(prompted_error)) end
            test.eq(quote.line(muse_launch.specification(prompted).argv), "-- --help")
            local native_resume, native_resume_error = muse_launch.decode({profile_id = "window", brief = "", resume_ref = "native-session"})
            if not native_resume then error(tostring(native_resume_error)) end
            test.eq(quote.line(muse_launch.specification(native_resume).argv), "resume native-session")
            local native_both, native_both_error = muse_launch.decode({profile_id = "window", brief = "--help", resume_ref = "native-session"})
            test.is_nil(native_both)
            test.eq(native_both_error, "window resume cannot carry a brief")
            local reply, call_error = funcs.call("bee.driver.muse:normalize", {index = 1,
                envelope = {payload_type = "runtime.command.accepted", stream = {id = "sess-1"}, payload = {}}})
            if call_error then error(tostring(call_error)) end
            test.is_true(reply.ok)
            test.eq(reply.state.session_id, "sess-1")
            local done = funcs.call("bee.driver.muse:normalize", {state = reply.state, index = 2, eof = true})
            test.eq(done.terminal.outcome, "uncertain")
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
