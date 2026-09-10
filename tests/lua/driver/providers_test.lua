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
local claude_launch = require("claude_launch")
local codex_launch = require("codex_launch")
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
            local request, err = claude_launch.decode({profile_id = "session", brief = "say hi", permission_mode = "dontAsk", max_turns = 2})
            if not request then error(tostring(err)) end
            local launch = claude_launch.specification(request)
            test.eq(launch.executable, "claude")
            test.eq(quote.line(launch.argv), "claude -p 'say hi' --output-format stream-json --verbose --include-partial-messages --permission-mode dontAsk --max-turns 2")
            local _, mode_error = claude_launch.decode({profile_id = "session", brief = "x", permission_mode = "bypassPermissions"})
            test.eq(mode_error, "permission_mode is not one Bee admits")
            local resumed = claude_launch.specification({profile_id = "session", brief = "next", permission_mode = "default", max_turns = 1, resume_ref = "sess-1", permission_exchange = false})
            test.eq(resumed.argv[#resumed.argv], "sess-1")
            -- The exchange launch: the brief is the first stream-json line
            -- on stdin, canonically encoded, stdin stays open, and prompts
            -- route to the stdio prompt tool.
            local exchange, exchange_error = claude_launch.decode({profile_id = "batch", brief = "leave a \"marker\"", permission_mode = "default", max_turns = 3, permission_exchange = true})
            if not exchange then error(tostring(exchange_error)) end
            local interactive = claude_launch.specification(exchange)
            test.eq(quote.line(interactive.argv), "claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --permission-mode default --max-turns 3 --permission-prompt-tool stdio --permission-prompts host")
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
            test.eq(quote.line(launch.argv), "codex exec --json --skip-git-repo-check --sandbox workspace-write -")
            local _, sandbox_error = codex_launch.decode({profile_id = "batch", brief = "x", sandbox = "danger-full-access"})
            test.eq(sandbox_error, "sandbox is not one Bee admits")
            local reply = funcs.call("bee.driver.codex:normalize", {index = 1, envelope = {type = "thread.started", thread_id = "t1"}})
            test.is_true(reply.ok)
            test.eq(reply.state.thread_id, "t1")
            local done = funcs.call("bee.driver.codex:normalize", {state = reply.state, index = 2, eof = true})
            test.eq(done.terminal.outcome, "uncertain")
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
