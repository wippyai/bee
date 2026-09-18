-- MIT. Codex CLI exec --json (protocol revision exec-json-1) into thread
-- observations. turn.completed and turn.failed are the only terminal
-- reports; the answer is the last agent_message of the turn.
local json = require("json")
local events = require("events")
local types = require("types")
local M = {}
M.PROTOCOL_REVISION = "exec-json-1"
type Observation = {[string]: unknown}
type State = {thread_id: string?, resumed: boolean, answer: string?, terminal: types.Terminal?}
type Step = {observations: {Observation}, terminal: types.Terminal?}
function M.new(resumed: boolean): State
    return {resumed = resumed}
end
local function key(index: integer, suffix: string): string
    return "codex:" .. tostring(index) .. ":" .. suffix
end
local function usage_of(value: unknown): {[string]: unknown}?
    if type(value) ~= "table" then return nil end
    local usage = value :: {[string]: unknown}
    return events.usage(usage.input_tokens, usage.output_tokens, usage.cached_input_tokens)
end
local function item_observations(state: State, index: integer, phase: string, item: {[string]: unknown}, out: {Observation})
    local id = tostring(item.id or ("item-" .. tostring(index)))
    local kind: unknown = item.type
    if kind == "agent_message" then
        if phase == "completed" and type(item.text) == "string" then
            state.answer = item.text
            for _, piece in ipairs(events.text(key(index, "message"), id, "complete", item.text, "answer")) do out[#out + 1] = piece end
        end
    elseif kind == "reasoning" then
        if type(item.text) == "string" and #item.text > 0 then
            for _, piece in ipairs(events.text(key(index, "reasoning"), id, "complete", item.text, "reasoning_summary")) do out[#out + 1] = piece end
        end
    elseif kind == "command_execution" then
        if phase == "started" then
            out[#out + 1] = events.tool_call(key(index, "command"), id, "command_execution", tostring(item.command))
        elseif phase == "completed" then
            local status: unknown = item.status
            local outcome = "succeeded"
            local fault: {code: string, message: string, retryable: boolean}? = nil
            if status ~= "completed" then
                outcome = "failed"
                fault = events.fault("exit_" .. tostring(item.exit_code), tostring(item.aggregated_output), false)
            end
            out[#out + 1] = events.tool_result(key(index, "result"), id, outcome, tostring(item.aggregated_output or ""), fault)
        end
    else
        local encoded, err = json.encode(item)
        out[#out + 1] = events.extension(key(index, "item"), "codex.item." .. tostring(kind), M.PROTOCOL_REVISION, (not err and encoded) or "{}")
    end
end
function M.normalize(state: State, index: integer, envelope: {[string]: unknown}): Step
    local out: {Observation} = {}
    local kind: unknown = envelope.type
    if state.terminal then
        out[#out + 1] = events.notice(key(index, "after-terminal"), "warning", "after_terminal", "envelope after the turn ended: " .. tostring(kind))
        return {observations = out}
    end
    if kind == "thread.started" then
        if type(envelope.thread_id) == "string" then state.thread_id = envelope.thread_id end
        local phase = "started"
        if state.resumed then phase = "resumed" end
        out[#out + 1] = events.session(key(index, "thread"), phase, state.thread_id)
    elseif kind == "turn.started" then
        out[#out + 1] = events.turn(key(index, "turn"), "started", nil, nil)
    elseif kind == "item.started" or kind == "item.updated" or kind == "item.completed" then
        local item: unknown = envelope.item
        if type(item) == "table" then item_observations(state, index, tostring(kind):sub(6), item :: {[string]: unknown}, out) end
    elseif kind == "error" then
        out[#out + 1] = events.notice(key(index, "error"), "warning", "provider_error", tostring(envelope.message))
    elseif kind == "turn.completed" then
        local usage = usage_of(envelope.usage)
        out[#out + 1] = events.turn(key(index, "turn"), "ended", "succeeded", usage)
        state.terminal = {outcome = "succeeded", answer = state.answer, resume_ref = state.thread_id, usage = usage}
        return {observations = out, terminal = state.terminal}
    elseif kind == "turn.failed" then
        local message = "turn failed"
        local detail: unknown = envelope.error
        if type(detail) == "table" and type((detail :: {[string]: unknown}).message) == "string" then message = tostring((detail :: {[string]: unknown}).message) end
        out[#out + 1] = events.turn(key(index, "turn"), "ended", "failed", usage_of(envelope.usage))
        state.terminal = {outcome = "failed", resume_ref = state.thread_id, error = events.fault("turn_failed", message, false)}
        return {observations = out, terminal = state.terminal}
    else
        local encoded, err = json.encode(envelope)
        out[#out + 1] = events.extension(key(index, "event"), "codex." .. tostring(kind), M.PROTOCOL_REVISION, (not err and encoded) or "{}")
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
    local terminal: types.Terminal = {outcome = "uncertain", resume_ref = state.thread_id, error = events.fault("stream_ended", "the stream ended without turn.completed", false)}
    state.terminal = terminal
    return {observations = out, terminal = terminal}
end
return M
