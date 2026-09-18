-- MIT. Claude Code stream-json (protocol revision stream-json-2) into thread
-- observations. The only terminal report is the result envelope; a stream
-- that ends without one is uncertain, whatever the process exit says.
local json = require("json")
local events = require("events")
local types = require("types")
local M = {}
M.PROTOCOL_REVISION = "stream-json-2"
type Observation = {[string]: unknown}
type State = {
    session_id: string?,
    started: boolean,
    resumed: boolean,
    terminal: types.Terminal?,
    segments: {[string]: boolean},
    tools: {[string]: string},
}
type Step = {observations: {Observation}, terminal: types.Terminal?}
function M.new(resumed: boolean): State
    local segments: {[string]: boolean} = {}
    local tools: {[string]: string} = {}
    local state: State = {started = false, resumed = resumed, segments = segments, tools = tools}
    return state
end
local function key(index: integer, suffix: string): string
    return "claude:" .. tostring(index) .. ":" .. suffix
end
local function text_of(value: unknown): string
    if type(value) == "string" then return value end
    if type(value) == "table" then
        local parts: {string} = {}
        for _, block in ipairs(value :: {unknown}) do
            if type(block) == "table" then
                local piece: unknown = (block :: {[string]: unknown}).text
                if type(piece) == "string" then parts[#parts + 1] = piece end
            end
        end
        if #parts > 0 then return table.concat(parts, "\n") end
        local encoded, err = json.encode(value)
        if not err and encoded then return encoded end
    end
    return tostring(value)
end
local function usage_of(value: unknown): {[string]: unknown}?
    if type(value) ~= "table" then return nil end
    local usage = value :: {[string]: unknown}
    return events.usage(usage.input_tokens, usage.output_tokens, usage.cache_read_input_tokens)
end
local function content_blocks(state: State, index: integer, message: unknown, out: {Observation})
    if type(message) ~= "table" then return end
    local content: unknown = (message :: {[string]: unknown}).content
    if type(content) ~= "table" then return end
    for position, block in ipairs(content :: {unknown}) do
        if type(block) == "table" then
            local item = block :: {[string]: unknown}
            local suffix = "block" .. tostring(position)
            if item.type == "text" and type(item.text) == "string" then
                local segment = "assistant:" .. tostring(index) .. ":" .. tostring(position)
                for _, piece in ipairs(events.text(key(index, suffix), segment, "complete", item.text, "answer")) do out[#out + 1] = piece end
            elseif item.type == "tool_use" and type(item.id) == "string" and type(item.name) == "string" then
                local input_text = "{}"
                local encoded, err = json.encode(item.input)
                if not err and encoded then input_text = encoded end
                state.tools[item.id] = item.name
                out[#out + 1] = events.tool_call(key(index, suffix), item.id, item.name, input_text)
            elseif item.type == "tool_result" and type(item.tool_use_id) == "string" then
                local outcome = "succeeded"
                local fault: {code: string, message: string, retryable: boolean}? = nil
                if item.is_error == true then
                    outcome = "failed"
                    fault = events.fault("tool_error", text_of(item.content), false)
                end
                out[#out + 1] = events.tool_result(key(index, suffix), item.tool_use_id, outcome, text_of(item.content), fault)
            elseif item.type == "thinking" then
                local summary: unknown = item.thinking
                if type(summary) == "string" and #summary > 0 then
                    for _, piece in ipairs(events.text(key(index, suffix), "thinking:" .. tostring(index), "complete", summary, "reasoning_summary")) do out[#out + 1] = piece end
                end
            end
        end
    end
end
-- One envelope in, observations out; the terminal report only from result.
function M.normalize(state: State, index: integer, envelope: {[string]: unknown}): Step
    local out: {Observation} = {}
    local kind: unknown = envelope.type
    if state.terminal then
        out[#out + 1] = events.notice(key(index, "after-result"), "warning", "after_result", "envelope after the result: " .. tostring(kind))
        return {observations = out}
    end
    if kind == "system" then
        local subtype: unknown = envelope.subtype
        if subtype == "init" then
            local session: unknown = envelope.session_id
            if type(session) == "string" then state.session_id = session end
            state.started = true
            local phase = "started"
            if state.resumed then phase = "resumed" end
            out[#out + 1] = events.session(key(index, "init"), phase, state.session_id)
            out[#out + 1] = events.turn(key(index, "turn"), "started", nil, nil)
        elseif subtype == "permission_denied" then
            out[#out + 1] = events.notice(key(index, "denied"), "warning", "permission_denied", tostring(envelope.tool_name) .. ": " .. tostring(envelope.message))
        elseif subtype == "api_retry" then
            out[#out + 1] = events.notice(key(index, "retry"), "warning", "api_retry", tostring(envelope.error) .. " attempt " .. tostring(envelope.attempt))
        elseif subtype == "informational" then
            local level = "info"
            if envelope.level == "warning" then level = "warning" end
            out[#out + 1] = events.notice(key(index, "info"), level, "informational", text_of(envelope.content))
        elseif subtype == "compact_boundary" then
            out[#out + 1] = events.notice(key(index, "compact"), "info", "compact_boundary", "context compacted")
        else
            local encoded, err = json.encode(envelope)
            out[#out + 1] = events.extension(key(index, "system"), "claude.system." .. tostring(subtype), M.PROTOCOL_REVISION, (not err and encoded) or "{}")
        end
    elseif kind == "assistant" or kind == "user" then
        content_blocks(state, index, envelope.message, out)
    elseif kind == "stream_event" then
        local event: unknown = envelope.event
        if type(event) == "table" then
            local inner = event :: {[string]: unknown}
            if inner.type == "content_block_delta" and type(inner.delta) == "table" then
                local delta = inner.delta :: {[string]: unknown}
                if delta.type == "text_delta" and type(delta.text) == "string" then
                    local segment = "stream:" .. tostring(inner.index)
                    for _, piece in ipairs(events.text(key(index, "delta"), segment, "append", delta.text, "answer")) do out[#out + 1] = piece end
                end
            end
        end
    elseif kind == "result" then
        local session: unknown = envelope.session_id
        if type(session) == "string" then state.session_id = session end
        local is_error = envelope.is_error == true
        local subtype: unknown = envelope.subtype
        local outcome = "succeeded"
        local fault: {code: string, message: string, retryable: boolean}? = nil
        if is_error or subtype ~= "success" then
            outcome = "failed"
            local reason = tostring(envelope.terminal_reason or subtype or "error")
            fault = events.fault(reason, text_of(envelope.result), reason == "api_error" or reason == "rate_limit")
        end
        local denials: unknown = envelope.permission_denials
        if type(denials) == "table" then
            for position, denial in ipairs(denials :: {unknown}) do
                if type(denial) == "table" then
                    local item = denial :: {[string]: unknown}
                    out[#out + 1] = events.notice(key(index, "denial" .. tostring(position)), "warning", "permission_denied", tostring(item.tool_name) .. " " .. tostring(item.tool_use_id))
                end
            end
        end
        local usage = usage_of(envelope.usage)
        out[#out + 1] = events.turn(key(index, "turn"), "ended", outcome, usage)
        local answer: string? = nil
        if outcome == "succeeded" and type(envelope.result) == "string" then answer = envelope.result end
        state.terminal = {outcome = outcome :: types.Outcome, answer = answer, resume_ref = state.session_id, usage = usage, error = fault}
        return {observations = out, terminal = state.terminal}
    else
        local encoded, err = json.encode(envelope)
        out[#out + 1] = events.extension(key(index, "event"), "claude." .. tostring(kind), M.PROTOCOL_REVISION, (not err and encoded) or "{}")
    end
    return {observations = out}
end
-- The stream ended: without a result the turn is uncertain; the process
-- exit never turns that into success.
function M.finish(state: State, index: integer): Step
    if state.terminal then
        local none: {Observation} = {}
        local quiet: Step = {observations = none}
        return quiet
    end
    local out: {Observation} = {events.turn(key(index, "eof"), "ended", "uncertain", nil)}
    local terminal: types.Terminal = {outcome = "uncertain", resume_ref = state.session_id, error = events.fault("stream_ended", "the stream ended without a result envelope", false)}
    state.terminal = terminal
    return {observations = out, terminal = terminal}
end
return M
