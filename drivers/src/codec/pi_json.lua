-- SPDX-License-Identifier: MIT
-- Pi 0.73.1 print JSON. agent_end closes an agent loop, including loops Pi
-- retries internally. Settle only at EOF after the last agent_end; a
-- turn_end may precede tool execution and is never a terminal.
local json = require("json")
local events = require("events")
local types = require("types")
local bounds = require("bounds")
local values = require("values")
local M = {}
M.PROTOCOL_REVISION = "pi-json-1"
M.MAX_ANSWER_BYTES = events.MAX_TEXT_BYTES
type Observation = {[string]: unknown}
type State = {
    session_id: string?, started: boolean, resumed: boolean, completed: boolean,
    answer: string?, answer_truncated: boolean, stop: string?,
    error: types.Fault?, usage: types.Usage?, terminal: types.Terminal?,
}
type Step = {observations: {Observation}, terminal: types.Terminal?}
function M.new(resumed: boolean): State
    return {started = false, resumed = resumed, completed = false, answer_truncated = false}
end
function M.decode_state(value: unknown): (State?, string?)
    local object = bounds.object(value)
    if not object or bounds.fields(object, {"session_id", "started", "resumed", "completed", "answer", "answer_truncated", "stop", "error", "usage", "terminal"}) then
        return nil, "state has invalid fields"
    end
    if type(object.started) ~= "boolean" or type(object.resumed) ~= "boolean" or type(object.completed) ~= "boolean" or type(object.answer_truncated) ~= "boolean" then
        return nil, "state flags must be booleans"
    end
    local session_id: string? = nil
    if object.session_id ~= nil then
        session_id = bounds.id(object.session_id)
        if not session_id then return nil, "state.session_id is invalid" end
    end
    local answer: string? = nil
    if object.answer ~= nil then
        answer = bounds.text(object.answer, M.MAX_ANSWER_BYTES)
        if not answer or object.answer_truncated then return nil, "state.answer exceeds the retained answer bound" end
    end
    local stop: string? = nil
    if object.stop ~= nil then
        stop = bounds.member(object.stop, {"stop", "length", "toolUse", "error", "aborted"})
        if not stop then return nil, "state.stop is invalid" end
    end
    local fault, fault_error = events.decode_fault(object.error, "state.error", 4096)
    if fault_error then return nil, fault_error end
    local usage: types.Usage? = nil
    if object.usage ~= nil then
        local usage_error: string?
        usage, usage_error = values.usage(object.usage)
        if usage_error then return nil, usage_error end
    end
    local terminal: types.Terminal? = nil
    if object.terminal ~= nil then
        local decoded, err = types.decode_terminal(object.terminal)
        if not decoded then return nil, err end
        if decoded.answer and #decoded.answer > M.MAX_ANSWER_BYTES then
            return nil, "state.terminal.answer exceeds the retained answer bound"
        end
        terminal = decoded
    end
    return {session_id = session_id, started = object.started, resumed = object.resumed, completed = object.completed,
        answer = answer, answer_truncated = object.answer_truncated, stop = stop, error = fault, usage = usage, terminal = terminal}, nil
end
local function key(index: integer, suffix: string): string return "pi:" .. tostring(index) .. ":" .. suffix end
local function encoded(value: unknown): string
    local text, err = json.encode(value)
    return (not err and text) or "{}"
end
local function extension(index: integer, kind: string, envelope: {[string]: unknown}): Observation
    return events.extension(key(index, "event"), "pi." .. kind, M.PROTOCOL_REVISION, encoded(envelope))
end
local function fault(message: unknown): types.Fault
    local text = type(message) == "string" and message or "Pi reports an API error"
    -- Pi's provider serializes HTTP status at the start of errorMessage.
    -- Unknown errors and other 4xx responses are not retryable.
    local raw_status = text:match("^(%d%d%d)%s")
    local status = tonumber(raw_status)
    local lower = text:lower()
    local retryable = status ~= nil and (status == 429 or (status >= 500 and status <= 599))
    if status == nil then
        retryable = lower:find("rate_limit", 1, true) ~= nil or lower:find("rate limit", 1, true) ~= nil
            or lower:find("overloaded_error", 1, true) ~= nil or lower:find("server_error", 1, true) ~= nil
    end
    return events.fault("api_error", text, retryable)
end
local function summary(state: State, index: integer, message: {[string]: unknown}, out: {Observation})
    state.stop = bounds.member(message.stopReason, {"stop", "length", "toolUse", "error", "aborted"})
    state.error = nil
    if state.stop == "error" then state.error = fault(message.errorMessage)
    elseif state.stop == "aborted" then state.error = events.fault("aborted", "Pi request aborted", false) end
    -- The last assistant message is the answer, not the tool preambles.
    state.answer, state.answer_truncated = nil, false
    local content = bounds.array(message.content, 65536) or {}
    for _, raw in ipairs(content) do
        local block = bounds.object(raw)
        if block and block.type == "text" and type(block.text) == "string" and not state.answer_truncated then
            local current = state.answer or ""
            if #current + #block.text <= M.MAX_ANSWER_BYTES then state.answer = current .. block.text
            else
                state.answer, state.answer_truncated = nil, true
                out[#out + 1] = events.notice(key(index, "answer-bound"), "warning", "answer_truncated", "Pi answer exceeds the retained answer bound; text observations remain complete")
            end
        end
    end
    local raw_usage = bounds.object(message.usage)
    if raw_usage then
        local usage = events.usage(raw_usage.input, raw_usage.output, raw_usage.cacheRead)
        if usage then
            local total = state.usage or {}
            for _, name in ipairs({"input_tokens", "output_tokens", "cached_tokens"}) do
                local previous, current = bounds.count(total[name]) or 0, bounds.count(usage[name]) or 0
                total[name] = math.min(previous + current, bounds.MAX_SAFE_INTEGER)
            end
            state.usage = total
        end
    end
end
function M.normalize(state: State, index: integer, envelope: {[string]: unknown}, paths: {[string]: unknown}?): Step
    local out: {Observation} = {}
    local kind = type(envelope.type) == "string" and envelope.type or "unknown"
    if state.terminal then
        out[#out + 1] = events.notice(key(index, "after-terminal"), "warning", "after_terminal", "envelope after the turn ends: " .. kind)
        return {observations = out}
    end
    if kind == "session" then
        local id = bounds.id(envelope.id)
        if not id then out[#out + 1] = events.notice(key(index, "session"), "warning", "invalid_session", "Pi sends an invalid session identifier")
        elseif state.session_id and state.session_id ~= id then
            out[#out + 1] = events.notice(key(index, "session"), "warning", "session_mismatch", "Pi changes the session identifier during a run")
        else state.session_id = id end
    elseif kind == "agent_start" then
        state.completed = false
        state.stop, state.error = nil, nil
        if not state.started then
            state.started = true
            out[#out + 1] = events.session(key(index, "session"), state.resumed and "resumed" or "started", state.session_id)
            out[#out + 1] = events.turn(key(index, "turn"), "started", nil, nil)
        end
    elseif kind == "message_update" then
        local update = bounds.object(envelope.assistantMessageEvent)
        if update and (update.type == "text_delta" or update.type == "thinking_delta") and type(update.delta) == "string" and #update.delta > 0 then
            local channel = update.type == "text_delta" and "answer" or "reasoning_summary"
            for _, piece in ipairs(events.text(key(index, "delta"), channel, "append", update.delta, channel)) do out[#out + 1] = piece end
        end
    elseif kind == "message_end" then
        local message = bounds.object(envelope.message)
        if message and message.role == "assistant" then summary(state, index, message, out) end
    elseif kind == "tool_execution_start" then
        local id, name = bounds.id(envelope.toolCallId), bounds.id(envelope.toolName)
        if id and name then out[#out + 1] = events.tool_call(key(index, "call"), id, name, encoded(envelope.args))
        else out[#out + 1] = extension(index, kind, envelope) end
    elseif kind == "tool_execution_end" then
        local id = bounds.id(envelope.toolCallId)
        if id and type(envelope.isError) == "boolean" then
            local result = bounds.object(envelope.result)
            local output = result and encoded(result.content) or "{}"
            local error = envelope.isError and events.fault("tool_error", output, false) or nil
            out[#out + 1] = events.tool_result(key(index, "result"), id, envelope.isError and "failed" or "succeeded", output, error)
        else out[#out + 1] = extension(index, kind, envelope) end
    elseif kind == "agent_end" then
        local messages = bounds.array(envelope.messages, 65536)
        local last = messages and bounds.object(messages[#messages])
        state.completed = state.started and last ~= nil and last.role == "assistant" and last.stopReason == state.stop
    elseif kind == "auto_retry_start" then
        state.completed = false
        out[#out + 1] = extension(index, kind, envelope)
    elseif kind ~= "message_start" and kind ~= "turn_start" and kind ~= "turn_end" then
        out[#out + 1] = extension(index, kind, envelope)
    end
    return {observations = out}
end
function M.finish(state: State, index: integer): Step
    if state.terminal then return {observations = {}} end
    local outcome: types.Outcome = "uncertain"
    local error = events.fault("stream_ended", "the stream ends without a final agent_end", false)
    if state.completed then
        if state.stop == "stop" then outcome, error = "succeeded", nil
        elseif state.stop == "error" then outcome, error = "failed", state.error
        elseif state.stop == "aborted" then outcome, error = "cancelled", state.error
        elseif state.stop == "length" then outcome, error = "failed", events.fault("max_tokens", "Pi reaches the model output limit", false) end
    end
    local answer = outcome == "succeeded" and not state.answer_truncated and state.answer or nil
    state.terminal = {outcome = outcome, answer = answer, usage = state.usage, error = error}
    return {observations = {events.turn(key(index, "end"), "ended", outcome, state.usage)}, terminal = state.terminal}
end
return M
