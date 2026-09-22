-- MIT. Builders for the observations a normalizer emits. Each builder
-- returns a table that bee.threads.records:observation decodes; the caller
-- supplies the event key so repeats deduplicate at the authority.
local bounds = require("bounds")
local M = {}
M.MAX_TEXT_BYTES = 12288
type Content = {text: string?, artifact_ref: string?}
type Observation = {[string]: unknown}
local function content(text: string): Content
    if #text == 0 then return {text = " "} end
    return {text = text}
end
M.content = content
function M.session(event_key: string, state: string, resume_ref: string?): Observation
    return {type = "session.state", event_key = event_key, data = {type = "session.state", state = state, resume_ref = resume_ref}}
end
function M.turn(event_key: string, phase: string, reported_outcome: string?, usage: {[string]: unknown}?): Observation
    local data: {[string]: unknown} = {type = "turn.signal", phase = phase}
    if reported_outcome then data.reported_outcome = reported_outcome end
    if usage then data.usage = usage end
    return {type = "turn.signal", event_key = event_key, data = data}
end
-- Splits long text into bounded segments so every observation fits a record.
function M.text(event_key: string, segment_id: string, operation: string, text: string, channel: string): {Observation}
    local pieces: {Observation} = {}
    local total = #text
    local offset = 1
    local index = 0
    repeat
        local piece = text:sub(offset, offset + M.MAX_TEXT_BYTES - 1)
        local key = event_key
        if index > 0 then key = event_key .. "#" .. tostring(index) end
        local op = operation
        if index > 0 and operation == "replace" then op = "append" end
        pieces[#pieces + 1] = {type = "text", event_key = key, data = {type = "text", segment_id = segment_id, operation = op, text = piece, channel = channel}}
        offset = offset + M.MAX_TEXT_BYTES
        index = index + 1
    until offset > total
    return pieces
end
function M.tool_call(event_key: string, call_id: string, tool_name: string, input: string): Observation
    return {type = "tool.call", event_key = event_key, data = {type = "tool.call", call_id = call_id, tool_name = tool_name, input = content(input:sub(1, M.MAX_TEXT_BYTES))}}
end
function M.tool_result(event_key: string, call_id: string, outcome: string, output: string, fault: {code: string, message: string, retryable: boolean}?): Observation
    local data: {[string]: unknown} = {type = "tool.result", call_id = call_id, outcome = outcome, output = content(output:sub(1, M.MAX_TEXT_BYTES))}
    if fault then data.error = fault end
    return {type = "tool.result", event_key = event_key, data = data}
end
function M.notice(event_key: string, level: string, code: string, text: string): Observation
    return {type = "notice", event_key = event_key, data = {type = "notice", level = level, code = code, content = content(text:sub(1, M.MAX_TEXT_BYTES))}}
end
function M.extension(event_key: string, event_name: string, event_revision: string, payload_json: string): Observation
    return {type = "extension", event_key = event_key, data = {type = "extension", event_name = event_name, event_revision = event_revision, payload_json = payload_json:sub(1, M.MAX_TEXT_BYTES)}}
end
-- Usage as the records contract expects it; unknown counters stay absent.
function M.usage(input_tokens: unknown, output_tokens: unknown, cached_tokens: unknown): {[string]: unknown}?
    local usage: {[string]: unknown} = {}
    local any = false
    for name, value in pairs({input_tokens = input_tokens, output_tokens = output_tokens, cached_tokens = cached_tokens}) do
        local count = bounds.count(value)
        if count then
            usage[name] = count
            any = true
        end
    end
    if not any then return nil end
    return usage :: {[string]: unknown}
end
function M.fault(code: string, message: string, retryable: boolean): {code: string, message: string, retryable: boolean}
    return {code = bounds.id(code) or "unknown", message = message:sub(1, 4096), retryable = retryable}
end
return M
