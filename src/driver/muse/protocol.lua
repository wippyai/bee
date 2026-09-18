-- MIT. Muse CLI exec --json (protocol revision msp-exec-1) into thread
-- observations. Only run.terminal.completed reports the turn; the answer
-- accumulates from run.output.delta text, and the exit code never decides.
local json = require("json")
local events = require("events")
local types = require("types")
local M = {}
M.PROTOCOL_REVISION = "msp-exec-1"
type Observation = {[string]: unknown}
type State = {session_id: string?, resumed: boolean, answer: string?, terminal: types.Terminal?}
type Step = {observations: {Observation}, terminal: types.Terminal?}
function M.new(resumed: boolean): State
    return {resumed = resumed}
end
local function key(index: integer, suffix: string): string
    return "muse:" .. tostring(index) .. ":" .. suffix
end
local function payload_of(envelope: {[string]: unknown}): {[string]: unknown}
    local payload: unknown = envelope.payload
    if type(payload) == "table" then return payload :: {[string]: unknown} end
    return {}
end
local function session_of(envelope: {[string]: unknown}): string?
    local stream: unknown = envelope.stream
    if type(stream) ~= "table" then return nil end
    local id: unknown = (stream :: {[string]: unknown}).id
    if type(id) == "string" then return id end
    return nil
end
local function extension(state: State, index: integer, kind: string, envelope: {[string]: unknown}, out: {Observation})
    local encoded, err = json.encode(envelope)
    out[#out + 1] = events.extension(key(index, "event"), "muse." .. kind, M.PROTOCOL_REVISION, (not err and encoded) or "{}")
end
function M.normalize(state: State, index: integer, envelope: {[string]: unknown}): Step
    local out: {Observation} = {}
    local raw: unknown = envelope.payload_type
    local kind = type(raw) == "string" and raw or "unknown"
    local session = session_of(envelope)
    if session then state.session_id = session end
    if state.terminal then
        out[#out + 1] = events.notice(key(index, "after-terminal"), "warning", "after_terminal", "envelope after the turn ended: " .. tostring(kind))
        return {observations = out}
    end
    local payload = payload_of(envelope)
    if kind == "runtime.command.accepted" then
        local phase = "started"
        if state.resumed then phase = "resumed" end
        out[#out + 1] = events.session(key(index, "session"), phase, state.session_id)
    elseif kind == "run.lifecycle.started" then
        out[#out + 1] = events.turn(key(index, "turn"), "started", nil, nil)
    elseif kind == "run.output.delta" then
        local text: unknown = payload.text
        if type(text) == "string" and #text > 0 then
            state.answer = (state.answer or "") .. text
            for _, piece in ipairs(events.text(key(index, "delta"), "answer", "append", text, "answer")) do out[#out + 1] = piece end
        end
    elseif kind == "task.lifecycle.failed" then
        local event: unknown = payload.event
        local reason = "task failed"
        local task: unknown = payload.task_id
        if type(event) == "table" then
            local detail = event :: {[string]: unknown}
            if type(detail.reason) == "string" then reason = detail.reason end
            if type(detail.task_id) == "string" then task = detail.task_id end
        end
        local call_id = type(task) == "string" and task or "task"
        out[#out + 1] = events.tool_result(key(index, "task"), call_id, "failed", reason, events.fault("task_failed", reason, false))
    elseif kind == "run.terminal.completed" then
        local terminal: unknown = payload.terminal
        local outcome: types.Outcome = "failed"
        if terminal == "completed" then
            outcome = "succeeded"
        elseif terminal == "cancelled" then
            outcome = "cancelled"
        end
        local answer: string? = nil
        local fault: {code: string, message: string, retryable: boolean}? = nil
        if outcome == "succeeded" then
            answer = state.answer
        else
            local reason: unknown = payload.reason
            local message = "run terminal: " .. tostring(terminal)
            if type(reason) == "string" and #reason > 0 then message = reason end
            fault = events.fault("run_" .. tostring(terminal), message, false)
        end
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
    local terminal: types.Terminal = {outcome = "uncertain", resume_ref = state.session_id, error = events.fault("stream_ended", "the stream ended without run.terminal.completed", false)}
    state.terminal = terminal
    return {observations = out, terminal = terminal}
end
return M
