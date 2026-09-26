-- MIT. OpenCode `run --format json` (protocol revision opencode-run-json-1)
-- into thread observations. The stream has no turn envelope: newline
-- delimited events carry step_start, text, tool_use and step_finish frames,
-- and the process exit ends the turn, so only the end of the stream reports
-- terminally. An error frame or an empty stream settles the turn from here;
-- the exit code never decides.
--
-- Shapes verified against opencode 1.18.32 live traces. Unknown envelope
-- types stay extension evidence; they never end the turn.
local json = require("json")
local events = require("events")
local types = require("types")
local bounds = require("bounds")
local M = {}
M.PROTOCOL_REVISION = "opencode-run-json-1"
M.MAX_ANSWER_BYTES = events.MAX_TEXT_BYTES
type Observation = {[string]: unknown}
type Fault = {code: string, message: string, retryable: boolean}
type State = {
    session_id: string?,
    started: boolean,
    resumed: boolean,
    answer: string?,
    answer_truncated: boolean,
    usage: {[string]: unknown}?,
    error: Fault?,
    terminal: types.Terminal?,
}
type Step = {observations: {Observation}, terminal: types.Terminal?}
function M.new(resumed: boolean): State
    return {resumed = resumed, started = false, answer_truncated = false}
end
local function key(index: integer, suffix: string): string
    return "opencode:" .. tostring(index) .. ":" .. suffix
end
local function text_of(value: unknown): string
    if type(value) == "string" then return value end
    if value == nil then return "" end
    local encoded, err = json.encode(value)
    if not err and encoded then return encoded end
    return tostring(value)
end
-- Step tokens are provider counters: input and output token counts with an
-- optional prompt-cache read count. Steps accumulate across one run.
local function accumulate_usage(state: State, value: unknown)
    if type(value) ~= "table" then return end
    local tokens = value :: {[string]: unknown}
    local cache: {[string]: unknown}? = nil
    if type(tokens.cache) == "table" then cache = tokens.cache :: {[string]: unknown} end
    local usage = events.usage(tokens.input, tokens.output, cache and cache.read)
    if not usage then return end
    local total = state.usage or {}
    for _, name in ipairs({"input_tokens", "output_tokens", "cached_tokens"}) do
        local previous = bounds.count(total[name]) or 0
        local current = bounds.count(usage[name]) or 0
        total[name] = previous + current
    end
    state.usage = total
end
local function observe_session(state: State, index: integer, envelope: {[string]: unknown}, out: {Observation})
    local raw: unknown = envelope.sessionID
    if raw == nil then return end
    local session = bounds.id(raw)
    if not session then
        out[#out + 1] = events.notice(key(index, "session"), "warning", "invalid_session", "opencode sent an invalid session identifier")
    elseif state.session_id == nil then
        state.session_id = session
    elseif state.session_id ~= session then
        out[#out + 1] = events.notice(key(index, "session"), "warning", "session_mismatch", "opencode changed the session identifier during a turn")
    end
end
local function ensure_started(state: State, index: integer, out: {Observation})
    if not state.started then
        state.started = true
        local phase = state.resumed and "resumed" or "started"
        out[#out + 1] = events.session(key(index, "session"), phase, state.session_id)
        out[#out + 1] = events.turn(key(index, "turn"), "started", nil, nil)
    end
end
local function retained_answer(state: State): string?
    if state.answer_truncated then return nil end
    return state.answer
end
local function error_fault(envelope: {[string]: unknown}): Fault
    local detail: unknown = envelope.error
    local name = "run_error"
    local message = "opencode reported an error"
    if type(detail) == "table" then
        local fields = detail :: {[string]: unknown}
        if bounds.id(fields.name) then name = fields.name :: string end
        local data: {[string]: unknown} = {}
        if type(fields.data) == "table" then data = fields.data :: {[string]: unknown} end
        if type(data.message) == "string" and #data.message > 0 then
            message = data.message :: string
        elseif type(fields.message) == "string" and #fields.message > 0 then
            message = fields.message :: string
        end
    elseif type(detail) == "string" and #detail > 0 then
        message = detail
    end
    return events.fault(name, message, false)
end
local function tool_observations(state: State, index: integer, envelope: {[string]: unknown}, out: {Observation})
    local part: unknown = envelope.part
    if type(part) ~= "table" then return end
    local body = part :: {[string]: unknown}
    local call_id = bounds.id(body.callID) or ("call-" .. tostring(index))
    local tool_name = bounds.id(body.tool) or "unknown"
    local detail: {[string]: unknown} = {}
    if type(body.state) == "table" then detail = body.state :: {[string]: unknown} end
    local input = "{}"
    if detail.input ~= nil then
        if type(detail.input) == "string" then
            input = detail.input :: string
        else
            local encoded, err = json.encode(detail.input)
            if not err and encoded then input = encoded end
        end
    end
    out[#out + 1] = events.tool_call(key(index, "tool_call"), call_id, tool_name, input)
    local status = type(detail.status) == "string" and (detail.status :: string):lower() or ""
    if status == "completed" then
        out[#out + 1] = events.tool_result(key(index, "tool_result"), call_id, "succeeded", text_of(detail.output), nil)
    elseif status == "error" then
        local reason = text_of(detail.error)
        if reason == "" then reason = "tool error" end
        out[#out + 1] = events.tool_result(key(index, "tool_result"), call_id, "failed", text_of(detail.output), events.fault("tool_error", reason, false))
    elseif status == "cancelled" or status == "canceled" then
        out[#out + 1] = events.tool_result(key(index, "tool_result"), call_id, "cancelled", text_of(detail.output), events.fault("tool_cancelled", "tool cancelled", false))
    else
        local encoded, err = json.encode(envelope)
        out[#out + 1] = events.extension(key(index, "tool_state"), "opencode.tool_state", M.PROTOCOL_REVISION, (not err and encoded) or "{}")
    end
end
-- Normalizer state is persisted by the carrier and returns as untrusted input.
-- Decode the complete, bounded schema rather than casting it back to State.
function M.decode_state(value: unknown): (State?, string?)
    local object = bounds.object(value)
    if not object then return nil, "state must be an object" end
    local unknown_field = bounds.fields(object, {"session_id", "started", "resumed", "answer", "answer_truncated", "usage", "error", "terminal"})
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
    if object.answer_truncated == true and answer ~= nil then
        return nil, "state.answer must be absent after truncation"
    end
    local usage: {[string]: unknown}? = nil
    if object.usage ~= nil then
        local usage_object = bounds.object(object.usage)
        if not usage_object then return nil, "state.usage must be an object" end
        local usage_unknown = bounds.fields(usage_object, {"input_tokens", "output_tokens", "cached_tokens"})
        if usage_unknown then return nil, "state.usage: " .. usage_unknown end
        usage = {}
        for _, name in ipairs({"input_tokens", "output_tokens", "cached_tokens"}) do
            local raw: unknown = usage_object[name]
            if raw ~= nil then
                local count = bounds.count(raw)
                if not count then return nil, "state.usage." .. name .. " is not a nonnegative integer" end
                usage[name] = count
            end
        end
    end
    local fault: Fault? = nil
    if object.error ~= nil then
        local error_object = bounds.object(object.error)
        if not error_object then return nil, "state.error must be an object" end
        local code = bounds.id(error_object.code)
        local message = bounds.text(error_object.message, 4096)
        if not code or not message or type(error_object.retryable) ~= "boolean" then return nil, "state.error is invalid" end
        fault = {code = code, message = message, retryable = error_object.retryable :: boolean}
    end
    local terminal: types.Terminal? = nil
    if object.terminal ~= nil then
        local terminal_object = bounds.object(object.terminal)
        if not terminal_object then return nil, "state.terminal must be an object" end
        local terminal_unknown = bounds.fields(terminal_object, {"outcome", "answer", "resume_ref", "usage", "error"})
        if terminal_unknown then return nil, "state.terminal: " .. terminal_unknown end
        local outcome = bounds.member(terminal_object.outcome, {"succeeded", "failed", "cancelled", "uncertain"})
        if not outcome then return nil, "state.terminal.outcome is not one outcome Bee admits" end
        local terminal_answer: string? = nil
        if terminal_object.answer ~= nil then
            terminal_answer = bounds.text(terminal_object.answer, M.MAX_ANSWER_BYTES)
            if not terminal_answer then return nil, "state.terminal.answer exceeds the retained answer bound" end
        end
        local resume_ref: string? = nil
        if terminal_object.resume_ref ~= nil then
            resume_ref = bounds.id(terminal_object.resume_ref)
            if not resume_ref then return nil, "state.terminal.resume_ref is not an identifier" end
        end
        local terminal_usage: {[string]: unknown}? = nil
        if terminal_object.usage ~= nil then
            local usage_object = bounds.object(terminal_object.usage)
            if not usage_object then return nil, "state.terminal.usage must be an object" end
            local usage_unknown = bounds.fields(usage_object, {"input_tokens", "output_tokens", "cached_tokens"})
            if usage_unknown then return nil, "state.terminal.usage: " .. usage_unknown end
            terminal_usage = {}
            for _, name in ipairs({"input_tokens", "output_tokens", "cached_tokens"}) do
                local raw: unknown = usage_object[name]
                if raw ~= nil then
                    local count = bounds.count(raw)
                    if not count then return nil, "state.terminal.usage." .. name .. " is not a nonnegative integer" end
                    terminal_usage[name] = count
                end
            end
        end
        local terminal_fault: Fault? = nil
        if terminal_object.error ~= nil then
            local error_object = bounds.object(terminal_object.error)
            if not error_object then return nil, "state.terminal.error must be an object" end
            local code = bounds.id(error_object.code)
            local message = bounds.text(error_object.message, 4096)
            if not code or not message or type(error_object.retryable) ~= "boolean" then return nil, "state.terminal.error is invalid" end
            terminal_fault = {code = code, message = message, retryable = error_object.retryable :: boolean}
        end
        terminal = {outcome = outcome :: types.Outcome, answer = terminal_answer, resume_ref = resume_ref, usage = terminal_usage, error = terminal_fault}
    end
    return {session_id = session_id, started = object.started :: boolean, resumed = object.resumed :: boolean,
        answer = answer, answer_truncated = object.answer_truncated :: boolean, usage = usage, error = fault,
        terminal = terminal}, nil
end
function M.normalize(state: State, index: integer, envelope: {[string]: unknown}): Step
    local out: {Observation} = {}
    local kind = type(envelope.type) == "string" and envelope.type :: string or "unknown"
    if state.terminal then
        out[#out + 1] = events.notice(key(index, "after-terminal"), "warning", "after_terminal", "envelope after the turn ended: " .. kind)
        return {observations = out}
    end
    observe_session(state, index, envelope, out)
    if kind == "step_start" then
        ensure_started(state, index, out)
    elseif kind == "text" then
        ensure_started(state, index, out)
        local part: unknown = envelope.part
        local text = ""
        if type(part) == "table" and type((part :: {[string]: unknown}).text) == "string" then text = (part :: {[string]: unknown}).text :: string end
        if #text > 0 then
            if not state.answer_truncated then
                local answer = (state.answer or "") .. text
                if #answer <= M.MAX_ANSWER_BYTES then
                    state.answer = answer
                else
                    state.answer = nil
                    state.answer_truncated = true
                    out[#out + 1] = events.notice(key(index, "answer-bound"), "warning", "answer_truncated", "OpenCode answer exceeded the retained answer bound; text observations remain complete")
                end
            end
            for _, piece in ipairs(events.text(key(index, "text"), "answer", "append", text, "answer")) do out[#out + 1] = piece end
        end
    elseif kind == "tool_use" then
        ensure_started(state, index, out)
        tool_observations(state, index, envelope, out)
    elseif kind == "step_finish" then
        -- A finished step is progress, not the turn: usage accumulates and
        -- the stream end reports terminally.
        ensure_started(state, index, out)
        local part: unknown = envelope.part
        if type(part) == "table" then accumulate_usage(state, (part :: {[string]: unknown}).tokens) end
    elseif kind == "error" then
        ensure_started(state, index, out)
        local fault = error_fault(envelope)
        state.error = fault
        out[#out + 1] = events.notice(key(index, "error"), "warning", "provider_error", fault.code .. ": " .. fault.message)
    else
        ensure_started(state, index, out)
        local encoded, err = json.encode(envelope)
        out[#out + 1] = events.extension(key(index, "event"), "opencode." .. kind, M.PROTOCOL_REVISION, (not err and encoded) or "{}")
    end
    return {observations = out}
end
function M.finish(state: State, index: integer): Step
    if state.terminal then
        local none: {Observation} = {}
        local quiet: Step = {observations = none}
        return quiet
    end
    local terminal: types.Terminal
    local out: {Observation} = {}
    if state.error then
        out[#out + 1] = events.turn(key(index, "eof"), "ended", "failed", state.usage)
        terminal = {outcome = "failed", resume_ref = state.session_id, usage = state.usage, error = state.error}
    elseif not state.started then
        out[#out + 1] = events.turn(key(index, "eof"), "ended", "uncertain", nil)
        terminal = {outcome = "uncertain", resume_ref = state.session_id,
            error = events.fault("stream_ended", "the stream ended without a completed step", false)}
    else
        out[#out + 1] = events.turn(key(index, "eof"), "ended", "succeeded", state.usage)
        terminal = {outcome = "succeeded", answer = retained_answer(state), resume_ref = state.session_id, usage = state.usage}
    end
    state.terminal = terminal
    return {observations = out, terminal = terminal}
end
return M
