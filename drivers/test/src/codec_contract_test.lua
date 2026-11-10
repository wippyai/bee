-- MIT. All codecs replay through the public normalizer with JSON checkpoints.
local test = require("test")
local fs = require("fs")
local funcs = require("funcs")
local json = require("json")
local bounds = require("bounds")
local stream_json = require("stream_json")
local observation = require("observation")
local driver_types = require("driver_types")
local records = require("records")
local values = require("values")
local events = require("events")
type Object = {[string]: unknown}
type Run = {observations: {Object}, terminal: driver_types.Terminal, segments: {[string]: string}}
local function object(raw: unknown): Object return assert(bounds.object(raw)) end
local function normalize(provider: string, state: unknown, index: integer, envelope: Object?, eof: boolean?): Object
    local raw, err = funcs.call("bee.drivers.universal:normalize", {
        descriptor_ref = "bee.drivers." .. provider .. ".descriptor:cli", state = state,
        index = index, envelope = envelope, eof = eof,
    })
    assert(not err, tostring(err))
    local reply = object(raw)
    assert(reply.ok == true, tostring(reply.error))
    return reply
end
local function replay(provider: string, path: string, size: integer?, drop_partials: boolean?): Run
    local content = assert(assert(fs.get("bee.drivers.tests:fixtures")):readfile(path .. ".jsonl"))
    local decoder = stream_json.new()
    local state: unknown = nil
    local terminal: driver_types.Terminal? = nil
    local observations: {Object} = {}
    local segments: {[string]: string} = {}
    local function accept(reply: Object)
        -- A fresh JSON value at every boundary catches fields lost by state decoders.
        state = json.decode(assert(json.encode(reply.state)))
        for _, raw in ipairs(assert(bounds.array(reply.observations, 65536))) do
            local decoded, err = observation.decode(raw)
            assert(decoded, tostring(err))
            local encoded = records.encode_body({kind = "observation", body = decoded})
            test.eq(assert(json.encode(json.decode(encoded))), assert(json.encode(decoded)))
            local item = object(raw)
            observations[#observations + 1] = item
            local data = object(item.data)
            if item.type == "text" and data.channel == "answer" then
                local id, text = tostring(data.segment_id), tostring(data.text)
                if data.operation == "append" then segments[id] = (segments[id] or "") .. text
                else segments[id] = text end
            end
        end
        if reply.terminal then terminal = assert(driver_types.decode_terminal(reply.terminal)) end
    end
    local chunk_size = size or 31
    for offset = 1, #content, chunk_size do
        local envelopes, problems = stream_json.feed(decoder, content:sub(offset, offset + chunk_size - 1))
        test.eq(#problems, 0)
        for _, envelope in ipairs(envelopes) do
            local value = object(envelope.value)
            if not (drop_partials and (value.type == "stream_event" or value.type == "message_update" or value.type == "item.updated")) then
                accept(normalize(provider, state, envelope.index, value))
            end
        end
    end
    test.is_nil(stream_json.finish(decoder))
    accept(normalize(provider, state, decoder.index + 1, nil, true))
    return {observations = observations, terminal = assert(terminal), segments = segments}
end
local function one_answer(run: Run, expected: string)
    local count = 0
    for _, text in pairs(run.segments) do count = count + 1; test.eq(text, expected) end
    test.eq(count, 1)
    test.eq(run.terminal.answer, expected)
    test.eq(run.terminal.outcome, "succeeded")
end
local function define_tests()
    test.describe("Common codec contract", function()
        test.it("replays every harness into exactly one complete answer segment", function()
            local cases = {
                {provider = "claude", path = "claude/stream-json-2/plain", answer = "pong"},
                {provider = "codex", path = "normalized/codex_stream", answer = "pong"},
                {provider = "agy", path = "agy/api-key-1.4.5/gemini", answer = "pong\n"},
                {provider = "grok", path = "normalized/grok_stream", answer = "pong"},
                {provider = "muse", path = "muse/msp-exec-1/echo", answer = "echo: say ok"},
                {provider = "opencode", path = "opencode/run-json-1/plain", answer = "pineapple"},
                {provider = "pi", path = "pi/json-1/plain", answer = "fixture answer"},
                {provider = "pi", path = "normalized/pi_stream", answer = "pong"},
            }
            for _, case in ipairs(cases) do
                for _, size in ipairs({7, 4096}) do one_answer(replay(case.provider, case.path, size), case.answer) end
            end
        end)
        test.it("keeps full-message-only streams complete", function()
            one_answer(replay("claude", "claude/stream-json-2/plain", 7, true), "pong")
            one_answer(replay("claude", "claude/stream-json-2/probe"), "pong")
            one_answer(replay("codex", "normalized/codex_stream", 7, true), "pong")
            one_answer(replay("pi", "normalized/pi_nonstream"), "pong")
        end)
        test.it("keeps distinct messages with identical content separate", function()
            for _, provider in ipairs({"claude", "pi"}) do
                local run = replay(provider, "normalized/" .. provider .. "_messages")
                local count = 0
                for _, text in pairs(run.segments) do count = count + 1; test.eq(text, "pong") end
                test.eq(count, 2)
            end
        end)
        test.it("retains reported Claude counters, cost and per-model usage", function()
            local run = replay("claude", "claude/stream-json-2/probe")
            local usage = assert(run.terminal.usage)
            test.eq(usage.input_tokens, 2); test.eq(usage.output_tokens, 4)
            test.eq(usage.cached_tokens, 11382); test.eq(usage.cache_write_tokens, 5575)
            test.eq(usage.reasoning_tokens, 0); test.eq(usage.cost_usd, 0.0234822)
            local model = assert(usage.models)["claude-sonnet-5-5"]
            test.eq(model.input_tokens, 2); test.eq(model.cached_tokens, 11382)
            test.eq(model.output_tokens, 4); test.eq(model.cache_write_tokens, 5575)
            test.eq(model.cost_usd, usage.cost_usd); test.eq(model.reasoning_tokens, 0)
        end)
        test.it("uses cumulative Codex token counts once and retains reasoning omitted by the final event", function()
            local usage = assert(replay("codex", "normalized/codex_stream").terminal.usage)
            test.eq(usage.input_tokens, 12); test.eq(usage.output_tokens, 7)
            test.eq(usage.cached_tokens, 3); test.eq(usage.reasoning_tokens, 2)
            test.eq(usage.cache_write_tokens, 4); test.is_nil(usage.cost_usd); test.is_nil(usage.models)
        end)
        test.it("preserves Agy thinking counts and reported model identity", function()
            local usage = assert(replay("agy", "agy/api-key-1.4.5/gemini").terminal.usage)
            test.eq(usage.input_tokens, 6657); test.eq(usage.output_tokens, 37)
            test.eq(usage.cached_tokens, 0); test.eq(usage.reasoning_tokens, 36)
            test.is_nil(usage.cache_write_tokens); test.is_nil(usage.cost_usd)
            test.eq(assert(usage.models)["gemini-api://gemini-3.5-flash-lite"].reasoning_tokens, 36)
        end)
        test.it("preserves OpenCode step cost, reasoning and cache writes", function()
            local usage = assert(replay("opencode", "opencode/run-json-1/plain").terminal.usage)
            test.eq(usage.input_tokens, 3); test.eq(usage.output_tokens, 7)
            test.eq(usage.cached_tokens, 0); test.eq(usage.cache_write_tokens, 8253)
            test.eq(usage.reasoning_tokens, 0); test.eq(usage.cost_usd, 0.03106275)
            test.is_nil(usage.models)
        end)
        test.it("maps Grok usage details and leaves unreported Muse fields absent", function()
            local run = replay("grok", "normalized/grok_stream")
            local usage = assert(run.terminal.usage)
            test.eq(usage.input_tokens, 12); test.eq(usage.output_tokens, 7)
            test.eq(usage.cached_tokens, 3); test.eq(usage.reasoning_tokens, 2)
            test.is_nil(usage.cache_write_tokens); test.is_nil(usage.cost_usd)
            test.is_nil(run.terminal.rate_limits)
            local muse = replay("muse", "muse/msp-exec-1/echo")
            test.is_nil(muse.terminal.usage); test.is_nil(muse.terminal.rate_limits)
        end)
        test.it("adds Pi messages and models while retaining reported zeros", function()
            local usage = assert(replay("pi", "normalized/pi_messages").terminal.usage)
            test.eq(usage.input_tokens, 12); test.eq(usage.output_tokens, 9)
            test.eq(usage.cached_tokens, 3); test.eq(usage.cache_write_tokens, 4)
            test.eq(usage.cost_usd, 0.3); test.is_nil(usage.reasoning_tokens)
            local models = assert(usage.models)
            test.eq(models["model-a"].input_tokens, 12)
            test.eq(models["model-b"].output_tokens, 2)
            test.eq(models["model-b"].input_tokens, 0)
            test.eq(models["model-b"].cached_tokens, 0)
            test.eq(models["model-b"].cost_usd, 0.05)
        end)
        test.it("normalizes rate windows, overage and allowed_warning", function()
            local run = replay("claude", "claude/stream-json-2/probe")
            local limits = assert(run.terminal.rate_limits)
            test.eq(limits.windows[1].window, "seven_day")
            test.eq(limits.windows[1].utilization, 0)
            test.eq(limits.windows[1].resets_at, 1794528000)
            test.eq(limits.windows[1].status, "allowed")
            test.eq(limits.overage_status, "rejected")
            test.eq(limits.overage_disabled_reason, "org_level_disabled")
            test.eq(limits.is_using_overage, false)
            local count = 0
            for _, item in ipairs(run.observations) do
                if item.type == "rate_limit" then
                    count = count + 1
                    test.eq(assert(json.encode(object(item.data).limits)), assert(json.encode(limits)))
                end
            end
            test.eq(count, 1)
            local warning = assert(replay("claude", "normalized/claude_warning").terminal.rate_limits)
            test.eq(warning.windows[1].status, "warning")
            test.eq(warning.windows[2].status, "allowed")
            test.eq(warning.is_using_overage, true)
            local codex = assert(replay("codex", "normalized/codex_stream").terminal.rate_limits)
            test.eq(codex.windows[1].window, "primary")
            test.eq(codex.windows[1].utilization, 0.01)
            test.eq(codex.windows[1].resets_at, 1794528000)
            test.eq(codex.windows[2].utilization, 0.825)
        end)
        test.it("retains retryable rate-limit failures for rejected windows", function()
            for _, provider in ipairs({"claude", "codex"}) do
                local terminal = replay(provider, "normalized/" .. provider .. "_rejected").terminal
                test.eq(terminal.outcome, "failed")
                test.eq(assert(terminal.error).code, "rate_limit")
                test.eq(assert(terminal.error).retryable, true)
                test.eq(assert(terminal.rate_limits).windows[1].status, "rejected")
            end
        end)
        test.it("keeps sparse usage sparse while adding disjoint reports", function()
            local total = assert(events.add_usage({input_tokens = 12}, {output_tokens = 3}))
            test.eq(total.input_tokens, 12); test.eq(total.output_tokens, 3)
            test.is_nil(total.cached_tokens); test.is_nil(total.cache_write_tokens)
            test.is_nil(total.reasoning_tokens); test.is_nil(total.cost_usd)
        end)
        test.it("rejects malformed portable usage and rate limits at typed boundaries", function()
            for _, raw in ipairs({{cost_usd = -1}, {cost_usd = math.huge}, {reasoning_tokens = 0.5},
                {cache_write_tokens = -1}, {models = {m = {models = {}}}}, {models = {m = {cost_usd = -1}}}}) do
                test.is_nil(values.usage(raw))
                test.is_nil(driver_types.decode_terminal({outcome = "succeeded", usage = raw}))
            end
            for _, raw in ipairs({{windows = {{window = "x", status = "warning", utilization = 1.1}}},
                {windows = {{window = "x", status = "invalid"}}}, {windows = {{window = "x", status = "allowed", resets_at = -1}}},
                {windows = {}, is_using_overage = "yes"}}) do
                test.is_nil(values.rate_limits(raw))
                test.is_nil(driver_types.decode_terminal({outcome = "succeeded", rate_limits = raw}))
                test.is_nil(observation.decode({type = "rate_limit", event_key = "bad", data = {type = "rate_limit", limits = raw}}))
            end
        end)
        test.it("folds bounded long snapshots without losing text or changing segment identity", function()
            local long_id = events.segment_id(string.rep("m", 160), "0")
            test.is_true(bounds.id(long_id) ~= nil)
            test.eq(long_id, events.segment_id(string.rep("m", 160), "0"))
            test.is_true(long_id ~= events.segment_id(string.rep("m", 160), "1"))
            local text = string.rep("text 😀 ", 5000)
            local folded = "partial"
            for _, raw in ipairs(events.text("long", "segment", "complete", text, "answer")) do
                local item = assert(observation.decode(raw))
                local data = object(item.data)
                test.eq(data.segment_id, "segment")
                if data.operation == "append" then folded = folded .. tostring(data.text) else folded = tostring(data.text) end
            end
            test.eq(folded, text)
        end)
    end)
end
return test.run_cases(define_tests)
