-- MIT. Grok CLI streaming-json into thread observations.
-- The only terminal report is the end envelope; a stream
-- that ends without one is uncertain, whatever the process exit says.
local json = require("json")
local events = require("events")
local types = require("types")
local bounds = require("bounds")

local M = {}
M.PROTOCOL_REVISION = "streaming-json-1"
M.MAX_ANSWER_BYTES = events.MAX_TEXT_BYTES

type Observation = {[string]: unknown}
type State = {
    session_id: string?,
    started: boolean,
    resumed: boolean,
    terminal: types.Terminal?,
    answer: string?,
    answer_truncated: boolean,
    usage: {[string]: unknown}?,
}
type Step = {observations: {Observation}, terminal: types.Terminal?}

function M.new(resumed: boolean): State
    local state: State = {
        session_id = nil,
        started = false,
        resumed = resumed,
        terminal = nil,
        answer = nil,
        answer_truncated = false,
        usage = nil,
    }
    return state
end

local function decode_usage(value: unknown): ({[string]: unknown}?, string?)
    if value == nil then return nil, nil end
    local object = bounds.object(value)
    if not object or bounds.fields(object, {"input_tokens", "output_tokens", "cached_tokens"}) then return nil, "usage must be an object with known counters" end
    local values: {[string]: unknown} = {}
    local count = 0
    for _, name in ipairs({"input_tokens", "output_tokens", "cached_tokens"}) do
        local raw = object[name]
        if raw ~= nil then
            local number = bounds.count(raw)
            if not number then return nil, "usage." .. name .. " is not a nonnegative integer" end
            values[name] = number
            count = count + 1
        end
    end
    if count == 0 then return nil, "usage must contain a counter" end
    return values :: {[string]: unknown}, nil
end

local function decode_terminal(value: unknown): types.Terminal?
    local object = bounds.object(value)
    if not object or bounds.fields(object, {"outcome", "answer", "resume_ref", "usage", "error"}) then return nil end
    local outcome = bounds.member(object.outcome, {"succeeded", "failed", "cancelled", "uncertain"})
    if not outcome then return nil end
    local answer: string? = nil
    if object.answer ~= nil then
        answer = bounds.text(object.answer, M.MAX_ANSWER_BYTES)
        if not answer then return nil end
    end
    local resume_ref: string? = nil
    if object.resume_ref ~= nil then
        resume_ref = bounds.id(object.resume_ref)
        if not resume_ref then return nil end
    end
    local usage, usage_error = decode_usage(object.usage)
    if usage_error then return nil end
    local fault: {code: string, message: string, retryable: boolean}? = nil
    if object.error ~= nil then
        local error_object = bounds.object(object.error)
        if not error_object or bounds.fields(error_object, {"code", "message", "retryable"}) then return nil end
        local code = bounds.id(error_object.code)
        local message = bounds.text(error_object.message, 4096)
        if not code or not message or type(error_object.retryable) ~= "boolean" then return nil end
        fault = {code = code, message = message, retryable = error_object.retryable :: boolean}
    end
    return {outcome = outcome :: types.Outcome, answer = answer, resume_ref = resume_ref, usage = usage, error = fault}
end

-- Normalizer state is persisted by the carrier and returns as untrusted input.
-- Decode the complete, bounded schema rather than casting it back to State.
function M.decode_state(value: unknown): (State?, string?)
    local object = bounds.object(value)
    if not object then return nil, "state must be an object" end
    local unknown_field = bounds.fields(object, {"session_id", "started", "resumed", "terminal", "answer", "answer_truncated", "usage"})
    if unknown_field then return nil, "state: " .. unknown_field end
    if type(object.started) ~= "boolean" or type(object.resumed) ~= "boolean" or type(object.answer_truncated) ~= "boolean" then
        return nil, "state has invalid flags"
    end
    local session_id: string? = nil
    if object.session_id ~= nil then
        session_id = bounds.id(object.session_id)
        if not session_id then return nil, "state.session_id is not an identifier" end
    end
    local answer: string? = nil
    if object.answer ~= nil then
        answer = bounds.text(object.answer, M.MAX_ANSWER_BYTES)
        if not answer then return nil, "state.answer exceeds the retained answer bound" end
    end
    if object.answer_truncated == true and answer ~= nil then return nil, "state.answer must be absent after truncation" end
    local terminal: types.Terminal? = nil
    if object.terminal ~= nil then
        terminal = decode_terminal(object.terminal)
        if not terminal then return nil, "state.terminal is invalid" end
    end
    local usage, usage_error = decode_usage(object.usage)
    if usage_error then return nil, "state." .. usage_error end
    return {session_id = session_id, started = object.started :: boolean, resumed = object.resumed :: boolean,
        terminal = terminal, answer = answer, answer_truncated = object.answer_truncated :: boolean, usage = usage}, nil
end

local function key(index: integer, suffix: string): string
    return "grok:" .. tostring(index) .. ":" .. suffix
end

local function text_of(value: unknown): string
    if type(value) == "string" then return value end
    if type(value) == "table" then
        local encoded, err = json.encode(value)
        if not err and encoded then return encoded end
    end
    return tostring(value or "")
end

local function usage_of(value: unknown): {[string]: unknown}?
    if type(value) ~= "table" then return nil end
    local usage = value :: {[string]: unknown}
    local input = usage.input_tokens or usage.prompt_tokens
    local output = usage.output_tokens or usage.completion_tokens
    local cached = usage.cache_read_input_tokens or usage.cached_input_tokens or usage.cached_tokens
    return events.usage(input, output, cached)
end

local function ensure_started(state: State, index: integer, out: {Observation})
    if not state.started then
        state.started = true
        local phase = state.resumed and "resumed" or "started"
        out[#out + 1] = events.session(key(index, "session"), phase, state.session_id)
        out[#out + 1] = events.turn(key(index, "turn_start"), "started", nil, nil)
    end
end

local function observe_session(state: State, index: integer, envelope: {[string]: unknown}, out: {Observation})
    local raw = envelope.sessionId or envelope.session_id
    if raw == nil then return end
    local session = bounds.id(raw)
    if not session then
        out[#out + 1] = events.notice(key(index, "session"), "warning", "invalid_session", "grok sent an invalid session identifier")
    elseif state.session_id == nil then
        state.session_id = session
    elseif state.session_id ~= session then
        out[#out + 1] = events.notice(key(index, "session"), "warning", "session_mismatch", "grok changed the session identifier during a turn")
    end
end

local function retained_answer(state: State): string?
    if state.answer_truncated then return nil end
    return state.answer
end

function M.normalize(state: State, index: integer, envelope: {[string]: unknown}): Step
    local out: {Observation} = {}
    local kind = tostring(envelope.type or envelope.event or "")

    if state.terminal then
        out[#out + 1] = events.notice(key(index, "after-terminal"), "warning", "after_terminal", "envelope after the turn ended: " .. kind)
        return {observations = out}
    end

    observe_session(state, index, envelope, out)

    ensure_started(state, index, out)

    if kind == "thought" then
        local raw = envelope.data ~= nil and envelope.data or envelope.text
        local text = text_of(raw)
        if #text > 0 then
            for _, piece in ipairs(events.text(key(index, "thought"), "reasoning", "append", text, "reasoning_summary")) do
                out[#out + 1] = piece
            end
        end
    elseif kind == "text" then
        local raw = envelope.data ~= nil and envelope.data or envelope.text
        local text = text_of(raw)
        if #text > 0 then
            if not state.answer_truncated then
                local answer = (state.answer or "") .. text
                if #answer <= M.MAX_ANSWER_BYTES then
                    state.answer = answer
                else
                    state.answer = nil
                    state.answer_truncated = true
                end
            end
            for _, piece in ipairs(events.text(key(index, "text"), "answer", "append", text, "answer")) do
                out[#out + 1] = piece
            end
        end
    elseif kind == "tool_call" then
        local call_id = tostring(envelope.toolCallId or envelope.tool_call_id or envelope.id or ("call-" .. tostring(index)))
        local name = tostring(envelope.toolName or envelope.tool_name or envelope.name or envelope.title or "unknown")
        local input_text = "{}"
        local raw_input = envelope.rawInput ~= nil and envelope.rawInput or envelope.input
        if raw_input ~= nil then
            if type(raw_input) == "string" then
                input_text = raw_input
            else
                local encoded, err = json.encode(raw_input)
                if not err and encoded then input_text = encoded end
            end
        end
        out[#out + 1] = events.tool_call(key(index, "tool_call"), call_id, name, input_text)
    elseif kind == "tool_call_update" then
        local call_id = tostring(envelope.toolCallId or envelope.tool_call_id or envelope.id or ("call-" .. tostring(index)))
        local status = string.lower(tostring(envelope.status or ""))
        local output_val = envelope.rawOutput ~= nil and envelope.rawOutput or envelope.output or envelope.result
        if status == "completed" then
            out[#out + 1] = events.tool_result(key(index, "tool_result"), call_id, "succeeded", text_of(output_val), nil)
        elseif status == "failed" or status == "error" or envelope.is_error == true then
            local output_text = text_of(output_val)
            local err_msg = output_text ~= "" and output_text or tostring(envelope.error or "tool error")
            out[#out + 1] = events.tool_result(key(index, "tool_result"), call_id, "failed", output_text, events.fault("tool_error", err_msg, false))
        else
            -- The streaming schema carries progress updates under this type.
            -- Unknown statuses are evidence only, never a completed tool result.
            local encoded, err = json.encode(envelope)
            out[#out + 1] = events.extension(key(index, "tool_update"), "grok.tool_call_update", M.PROTOCOL_REVISION, (not err and encoded) or "{}")
        end
    elseif kind == "usage" then
        local usage = usage_of(envelope.usage or envelope)
        if usage then
            state.usage = usage
        end
    elseif kind == "available_commands" then
        local encoded, err = json.encode(envelope)
        out[#out + 1] = events.extension(key(index, "commands"), "grok.available_commands", M.PROTOCOL_REVISION, (not err and encoded) or "{}")
    elseif kind == "plan" then
        local encoded, err = json.encode(envelope)
        out[#out + 1] = events.extension(key(index, "plan"), "grok.plan", M.PROTOCOL_REVISION, (not err and encoded) or "{}")
    elseif kind == "error" then
        local message = tostring(envelope.message or envelope.text or "grok error")
        out[#out + 1] = events.notice(key(index, "error"), "warning", "provider_error", message)
    elseif kind == "end" then
        local stop_reason = tostring(envelope.stopReason or envelope.stop_reason or "")
        local status = string.lower(tostring(envelope.status or ""))
        local outcome: types.Outcome = "succeeded"
        local fault: {code: string, message: string, retryable: boolean}? = nil

        if stop_reason == "cancelled" or stop_reason == "canceled" or status == "cancelled" or status == "canceled" then
            outcome = "cancelled"
        elseif envelope.is_error == true or status == "error" or status == "failed" or stop_reason == "error" or stop_reason == "failed" then
            outcome = "failed"
            local err_msg = tostring(envelope.error or envelope.message or (stop_reason ~= "" and stop_reason) or "turn failed")
            fault = events.fault("turn_failed", err_msg, false)
        elseif stop_reason == "end_turn" or stop_reason == "max_turn_requests" then
            outcome = "succeeded"
        else
            outcome = "uncertain"
            local reason = stop_reason ~= "" and stop_reason or (status ~= "" and status or "missing stop reason")
            fault = events.fault("unrecognized_stop_reason", tostring(envelope.message or reason), false)
        end

        local usage = usage_of(envelope.usage) or state.usage
        out[#out + 1] = events.turn(key(index, "turn_end"), "ended", outcome, usage)
        state.terminal = {
            outcome = outcome,
            answer = retained_answer(state),
            resume_ref = state.session_id,
            usage = usage,
            error = fault,
        }
        return {observations = out, terminal = state.terminal}
    else
        local encoded, err = json.encode(envelope)
        out[#out + 1] = events.extension(key(index, "event"), "grok." .. kind, M.PROTOCOL_REVISION, (not err and encoded) or "{}")
    end

    return {observations = out}
end

function M.finish(state: State, index: integer): Step
    if state.terminal then
        local none: {Observation} = {}
        local quiet: Step = {observations = none}
        return quiet
    end
    ensure_started(state, index, {})
    local out: {Observation} = {events.turn(key(index, "eof"), "ended", "uncertain", nil)}
    local terminal: types.Terminal = {
        outcome = "uncertain",
        answer = retained_answer(state),
        resume_ref = state.session_id,
        error = events.fault("stream_ended", "the stream ended without an end envelope", false),
    }
    state.terminal = terminal
    return {observations = out, terminal = terminal}
end

return M
