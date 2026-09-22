-- MIT. Muse CLI exec --json (protocol revision msp-exec-1) into thread
-- observations. Only run.terminal.completed reports the turn; the answer
-- accumulates from run.output.delta text, and the exit code never decides.
local json = require("json")
local events = require("events")
local types = require("types")
local bounds = require("bounds")

local M = {}
M.PROTOCOL_REVISION = "msp-exec-1"
M.MAX_ANSWER_BYTES = events.MAX_TEXT_BYTES

type Observation = {[string]: unknown}
type Fault = {code: string, message: string, retryable: boolean}
type State = {
    session_id: string?,
    resumed: boolean,
    command_accepted: boolean,
    run_started: boolean,
    answer: string?,
    answer_truncated: boolean,
    terminal: types.Terminal?,
}
type Step = {observations: {Observation}, terminal: types.Terminal?}

function M.new(resumed: boolean): State
    return {
        resumed = resumed,
        command_accepted = false,
        run_started = false,
        answer_truncated = false,
    }
end

local function key(index: integer, suffix: string): string
    return "muse:" .. tostring(index) .. ":" .. suffix
end

local function decode_fault(value: unknown, field: string): (Fault?, string?)
    if value == nil then return nil, nil end
    local object = bounds.object(value)
    if not object then return nil, field .. " must be an object" end
    local unknown_field = bounds.fields(object, {"code", "message", "retryable"})
    if unknown_field then return nil, field .. ": " .. unknown_field end
    local code = bounds.id(object.code)
    if not code then return nil, field .. ".code is not an identifier" end
    local message = bounds.text(object.message, bounds.MAX_FAULT_MESSAGE_BYTES)
    if not message then return nil, field .. ".message exceeds maximum fault message bytes" end
    if type(object.retryable) ~= "boolean" then return nil, field .. ".retryable must be a boolean" end
    return {code = code, message = message, retryable = object.retryable :: boolean}, nil
end

local function decode_terminal(value: unknown): (types.Terminal?, string?)
    local object = bounds.object(value)
    if not object then return nil, "state.terminal must be an object" end
    local unknown_field = bounds.fields(object, {"outcome", "answer", "resume_ref", "usage", "error"})
    if unknown_field then return nil, "state.terminal: " .. unknown_field end
    local outcome = bounds.member(object.outcome, {"succeeded", "failed", "cancelled", "uncertain"})
    if not outcome then return nil, "state.terminal.outcome is not one outcome Bee admits" end

    local answer: string? = nil
    if object.answer ~= nil then
        answer = bounds.text(object.answer, M.MAX_ANSWER_BYTES)
        if not answer then return nil, "state.terminal.answer exceeds the retained answer bound" end
    end
    local resume_ref: string? = nil
    if object.resume_ref ~= nil then
        resume_ref = bounds.id(object.resume_ref)
        if not resume_ref then return nil, "state.terminal.resume_ref is not an identifier" end
    end
    local usage: {[string]: unknown}? = nil
    if object.usage ~= nil then
        local usage_object = bounds.object(object.usage)
        if not usage_object then return nil, "state.terminal.usage must be an object" end
        local usage_unknown = bounds.fields(usage_object, {"input_tokens", "output_tokens", "cached_tokens"})
        if usage_unknown then return nil, "state.terminal.usage: " .. usage_unknown end
        usage = {}
        for _, name in ipairs({"input_tokens", "output_tokens", "cached_tokens"}) do
            local raw: unknown = usage_object[name]
            if raw ~= nil then
                local count = bounds.count(raw)
                if not count then return nil, "state.terminal.usage." .. name .. " is not a nonnegative integer" end
                usage[name] = count
            end
        end
    end
    local fault, fault_error = decode_fault(object.error, "state.terminal.error")
    if fault_error then return nil, fault_error end
    return {outcome = outcome :: types.Outcome, answer = answer, resume_ref = resume_ref, usage = usage, error = fault}, nil
end

-- Normalizer state is persisted by the carrier and returns as untrusted input.
-- Decode the complete, bounded schema rather than casting it back to State.
function M.decode_state(value: unknown): (State?, string?)
    local object = bounds.object(value)
    if not object then return nil, "state must be an object" end
    local unknown_field = bounds.fields(object, {"session_id", "resumed", "command_accepted", "run_started", "answer", "answer_truncated", "terminal"})
    if unknown_field then return nil, "state: " .. unknown_field end

    local session_id: string? = nil
    if object.session_id ~= nil then
        session_id = bounds.id(object.session_id)
        if not session_id then return nil, "state.session_id is not an identifier" end
    end
    if type(object.resumed) ~= "boolean" then return nil, "state.resumed must be a boolean" end
    if type(object.command_accepted) ~= "boolean" then return nil, "state.command_accepted must be a boolean" end
    if type(object.run_started) ~= "boolean" then return nil, "state.run_started must be a boolean" end
    if type(object.answer_truncated) ~= "boolean" then return nil, "state.answer_truncated must be a boolean" end

    local answer: string? = nil
    if object.answer ~= nil then
        answer = bounds.text(object.answer, M.MAX_ANSWER_BYTES)
        if not answer then return nil, "state.answer exceeds the retained answer bound" end
    end
    if object.answer_truncated == true and answer ~= nil then
        return nil, "state.answer must be absent after truncation"
    end

    local terminal: types.Terminal? = nil
    if object.terminal ~= nil then
        local decoded, terminal_error = decode_terminal(object.terminal)
        if not decoded then return nil, terminal_error end
        terminal = decoded
    end
    return {
        session_id = session_id,
        resumed = object.resumed :: boolean,
        command_accepted = object.command_accepted :: boolean,
        run_started = object.run_started :: boolean,
        answer = answer,
        answer_truncated = object.answer_truncated :: boolean,
        terminal = terminal,
    }, nil
end

local function payload_of(envelope: {[string]: unknown}): {[string]: unknown}
    local payload: unknown = envelope.payload
    if type(payload) == "table" then return payload :: {[string]: unknown} end
    return {}
end

local function observe_session(state: State, index: integer, envelope: {[string]: unknown}, out: {Observation})
    local stream: unknown = envelope.stream
    if type(stream) ~= "table" then return end
    local raw: unknown = (stream :: {[string]: unknown}).id
    if raw == nil then return end
    local session = bounds.id(raw)
    if not session then
        out[#out + 1] = events.notice(key(index, "session"), "warning", "invalid_session", "muse sent an invalid session identifier")
    elseif state.session_id == nil then
        state.session_id = session
    elseif state.session_id ~= session then
        out[#out + 1] = events.notice(key(index, "session"), "warning", "session_mismatch", "muse changed the session identifier during a turn")
    end
end

local function extension(state: State, index: integer, kind: string, envelope: {[string]: unknown}, out: {Observation})
    local encoded, err = json.encode(envelope)
    out[#out + 1] = events.extension(key(index, "event"), "muse." .. kind, M.PROTOCOL_REVISION, (not err and encoded) or "{}")
end

local function retained_answer(state: State): string?
    if state.answer_truncated then return nil end
    return state.answer
end

local function terminal_fault(terminal: unknown, payload: {[string]: unknown}): Fault
    local reason: unknown = payload.reason
    local message = "run terminal: " .. tostring(terminal)
    if type(reason) == "string" and #reason > 0 then message = reason end
    local suffix = type(terminal) == "string" and terminal ~= "" and terminal or "unknown"
    return events.fault("run_" .. suffix, message, false)
end

local function first_field(value: {[string]: unknown}, names: {string}): unknown
    local object = bounds.object(value)
    if not object then return nil end
    for _, name in ipairs(names) do
        local field = object[name]
        if field ~= nil then return field end
    end
    return nil
end

local function value_text(value: unknown): string
    if type(value) == "string" then return value end
    if value == nil then return "" end
    local encoded, err = json.encode(value)
    if not err and encoded then return encoded end
    return tostring(value)
end

local function tool_call(state: State, index: integer, payload: {[string]: unknown}, out: {Observation}): boolean
    local facts: {[string]: unknown} = {}
    if type(payload.correlation_facts) == "table" then facts = payload.correlation_facts :: {[string]: unknown} end
    local call_id = bounds.id(first_field(payload, {"call_id", "tool_call_id"}))
    local tool_name = bounds.id(first_field(payload, {"tool_name", "name"}) or facts.tool_name)
    if not call_id or not tool_name then return false end
    local raw_input = first_field(payload, {"input", "arguments", "params"})
    local input = raw_input == nil and "{}" or value_text(raw_input)
    out[#out + 1] = events.tool_call(key(index, "tool_call"), call_id, tool_name, input)
    return true
end

local function tool_outcome(value: unknown): string?
    if type(value) ~= "string" then return nil end
    local normalized = value:lower()
    if normalized == "success" or normalized == "succeeded" or normalized == "ok" or normalized == "completed" then return "succeeded" end
    if normalized == "failure" or normalized == "failed" or normalized == "error" or normalized == "errored" then return "failed" end
    if normalized == "cancelled" or normalized == "canceled" then return "cancelled" end
    return nil
end

local function tool_result(state: State, index: integer, payload: {[string]: unknown}, out: {Observation}): boolean
    local facts: {[string]: unknown} = {}
    if type(payload.correlation_facts) == "table" then facts = payload.correlation_facts :: {[string]: unknown} end
    local call_id = bounds.id(first_field(payload, {"call_id", "tool_call_id"}))
    if not call_id then return false end
    local raw_outcome = first_field(payload, {"outcome", "status"})
    if raw_outcome == nil then raw_outcome = facts.outcome end
    local outcome = tool_outcome(raw_outcome)
    if not outcome then return false end
    local output = value_text(first_field(payload, {"text", "output", "result"}))
    local fault: Fault? = nil
    if outcome ~= "succeeded" then
        local reason = output
        local raw_reason = first_field(payload, {"reason", "error"})
        if type(raw_reason) == "string" and #raw_reason > 0 then reason = raw_reason end
        local code = outcome == "cancelled" and "tool_cancelled" or "tool_error"
        fault = events.fault(code, reason, false)
    end
    out[#out + 1] = events.tool_result(key(index, "tool_result"), call_id, outcome, output, fault)
    return true
end

function M.normalize(state: State, index: integer, envelope: {[string]: unknown}): Step
    local out: {Observation} = {}
    local raw: unknown = envelope.payload_type
    local kind = type(raw) == "string" and raw or "unknown"
    if state.terminal then
        out[#out + 1] = events.notice(key(index, "after-terminal"), "warning", "after_terminal", "envelope after the turn ended: " .. tostring(kind))
        return {observations = out}
    end
    observe_session(state, index, envelope, out)
    local payload = payload_of(envelope)
    if kind == "runtime.command.accepted" then
        state.command_accepted = true
        local phase = state.resumed and "resumed" or "started"
        out[#out + 1] = events.session(key(index, "session"), phase, state.session_id)
    elseif kind == "run.lifecycle.started" then
        state.run_started = true
        out[#out + 1] = events.turn(key(index, "turn"), "started", nil, nil)
    elseif kind == "run.output.delta" then
        local text: unknown = payload.text
        if type(text) == "string" and #text > 0 then
            if not state.answer_truncated then
                local answer = (state.answer or "") .. text
                if #answer <= M.MAX_ANSWER_BYTES then
                    state.answer = answer
                else
                    state.answer = nil
                    state.answer_truncated = true
                    out[#out + 1] = events.notice(key(index, "answer-bound"), "warning", "answer_truncated", "Muse answer exceeded the retained answer bound; text observations remain complete")
                end
            end
            for _, piece in ipairs(events.text(key(index, "delta"), "answer", "append", text, "answer")) do out[#out + 1] = piece end
        end
    elseif kind == "tool.call" then
        if not tool_call(state, index, payload, out) then extension(state, index, tostring(kind), envelope, out) end
    elseif kind == "tool.result" then
        if not tool_result(state, index, payload, out) then extension(state, index, tostring(kind), envelope, out) end
    elseif kind == "task.lifecycle.failed" then
        -- Muse tasks also represent model and reminder work. A lifecycle task
        -- has no proved tool-call identity, so keep it provider-specific; only
        -- explicit tool.result envelopes become shared tool observations.
        extension(state, index, tostring(kind), envelope, out)
    elseif kind == "run.terminal.completed" then
        local terminal: unknown = payload.terminal
        local outcome: types.Outcome
        local fault: Fault? = nil
        if not state.command_accepted or not state.run_started then
            outcome = "uncertain"
            fault = events.fault("terminal_before_start", "run terminal arrived before command acceptance and run start", false)
            out[#out + 1] = events.notice(key(index, "terminal"), "warning", "terminal_before_start", "muse reported a terminal before command acceptance and run start")
        elseif terminal == "completed" then
            outcome = "succeeded"
        elseif terminal == "failed" then
            outcome = "failed"
            fault = terminal_fault(terminal, payload)
        elseif terminal == "cancelled" then
            outcome = "cancelled"
            fault = terminal_fault(terminal, payload)
        else
            outcome = "uncertain"
            fault = events.fault("run_terminal_unknown", "muse reported an unknown terminal: " .. tostring(terminal), false)
        end
        local answer: string? = nil
        if outcome == "succeeded" then answer = retained_answer(state) end
        out[#out + 1] = events.turn(key(index, "turn"), "ended", outcome, nil)
        state.terminal = {outcome = outcome, answer = answer, resume_ref = state.session_id, error = fault}
        return {observations = out, terminal = state.terminal}
    else
        extension(state, index, tostring(kind), envelope, out)
    end
    return {observations = out}
end

function M.finish(state: State, index: integer): Step
    if state.terminal then
        local none: {Observation} = {}
        local quiet: Step = {observations = none}
        return quiet
    end
    local out: {Observation} = {events.turn(key(index, "eof"), "ended", "uncertain", nil)}
    local terminal: types.Terminal = {outcome = "uncertain", answer = retained_answer(state), resume_ref = state.session_id, error = events.fault("stream_ended", "the stream ended without run.terminal.completed", false)}
    state.terminal = terminal
    return {observations = out, terminal = terminal}
end

return M
