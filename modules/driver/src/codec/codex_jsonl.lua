-- MIT. Codex CLI exec --json (protocol revision exec-json-1) into thread
-- observations. turn.completed and turn.failed are the only terminal
-- reports; the answer is the last agent_message of the turn.
local json = require("json")
local events = require("events")
local types = require("types")
local bounds = require("bounds")
local path_reader = require("paths")
local M = {}
M.PROTOCOL_REVISION = "exec-json-1"
type Observation = {[string]: unknown}
type State = {thread_id: string?, resumed: boolean, answer: string?, terminal: types.Terminal?}
type Step = {observations: {Observation}, terminal: types.Terminal?}
M.MAX_ANSWER_BYTES = 32768
function M.new(resumed: boolean): State
    return {resumed = resumed}
end
function M.decode_state(value: unknown): (State?, string?)
    local object = bounds.object(value)
    if not object then return nil, "state must be an object" end
    local unknown = bounds.fields(object, {"thread_id", "resumed", "answer", "terminal"})
    if unknown then return nil, "state: " .. unknown end
    if type(object.resumed) ~= "boolean" then return nil, "state.resumed must be a boolean" end
    local thread_id: string? = nil
    if object.thread_id ~= nil then
        thread_id = bounds.id(object.thread_id)
        if not thread_id then return nil, "state.thread_id is not an identifier" end
    end
    local answer: string? = nil
    if object.answer ~= nil then
        answer = bounds.text(object.answer, M.MAX_ANSWER_BYTES)
        if not answer then return nil, "state.answer exceeds the retained answer bound" end
    end
    local terminal: types.Terminal? = nil
    if object.terminal ~= nil then
        local decoded, terminal_error = types.decode_terminal(object.terminal)
        if not decoded then return nil, terminal_error end
        terminal = decoded
    end
    return {thread_id = thread_id, resumed = object.resumed, answer = answer, terminal = terminal}, nil
end
local function key(index: integer, suffix: string): string
    return "codex:" .. tostring(index) .. ":" .. suffix
end
local function usage_of(value: unknown): events.Usage?
    if type(value) ~= "table" then return nil end
    local usage = value
    return events.usage(usage.input_tokens, usage.output_tokens, usage.cached_input_tokens)
end
local function item_observations(state: State, index: integer, phase: string, item: {[string]: unknown}, envelope: {[string]: unknown}, paths: {[string]: unknown}?, out: {Observation})
    local id = tostring(item.id or ("item-" .. tostring(index)))
    local kind: unknown = item.type
    if kind == "agent_message" then
        local answer = path_reader.read(envelope, paths, "result_text")
        if phase == "completed" and type(answer) == "string" then
            state.answer = answer
            for _, piece in ipairs(events.text(key(index, "message"), id, "complete", answer, "answer")) do out[#out + 1] = piece end
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
function M.normalize(state: State, index: integer, envelope: {[string]: unknown}, paths: {[string]: unknown}?): Step
    local out: {Observation} = {}
    local kind: unknown = envelope.type
    if state.terminal then
        out[#out + 1] = events.notice(key(index, "after-terminal"), "warning", "after_terminal", "envelope after the turn ended: " .. tostring(kind))
        return {observations = out}
    end
    if kind == "thread.started" then
        local thread_id = path_reader.read(envelope, paths, "resume_id")
        if type(thread_id) == "string" then state.thread_id = thread_id end
        local phase = "started"
        if state.resumed then phase = "resumed" end
        out[#out + 1] = events.session(key(index, "thread"), phase, state.thread_id)
    elseif kind == "turn.started" then
        out[#out + 1] = events.turn(key(index, "turn"), "started", nil, nil)
    elseif kind == "item.started" or kind == "item.updated" or kind == "item.completed" then
        local item: unknown = envelope.item
        if type(item) == "table" then item_observations(state, index, tostring(kind):sub(6), item, envelope, paths, out) end
    elseif kind == "error" then
        out[#out + 1] = events.notice(key(index, "error"), "warning", "provider_error", tostring(path_reader.read(envelope, paths, "errors")))
    elseif kind == "turn.completed" then
        local usage = usage_of(path_reader.read(envelope, paths, "usage"))
        out[#out + 1] = events.turn(key(index, "turn"), "ended", "succeeded", usage)
        state.terminal = {outcome = "succeeded", answer = state.answer, resume_ref = state.thread_id, usage = usage}
        return {observations = out, terminal = state.terminal}
    elseif kind == "turn.failed" then
        local message = "turn failed"
        local detail: unknown = path_reader.read(envelope, paths, "errors")
        if type(detail) == "string" then message = detail end
        out[#out + 1] = events.turn(key(index, "turn"), "ended", "failed", usage_of(path_reader.read(envelope, paths, "usage")))
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
