-- MIT. Builders for the observations a normalizer emits. Each builder
-- returns a table that bee.threads.records:observation decodes; the caller
-- supplies the event key so repeats deduplicate at the authority.
local vocabulary = require("vocabulary")
local bounds = require("bounds")
local record_types = require("record_types")
local M = {}
M.MAX_TEXT_BYTES = 12288
M.MAX_ESCAPED_BYTES = 14336
local function segment_end(text: string, start: integer, budget: integer): integer
    local offset, cost = start, 0
    while offset <= #text do
        local byte = text:byte(offset)
        local width = byte >= 240 and 4 or byte >= 224 and 3 or byte >= 192 and 2 or 1
        local encoded = width
        if byte == 34 or byte == 92 then encoded = 4
        elseif byte < 32 or byte == 127 then encoded = 7 end
        if cost + encoded > budget or offset - start + width > M.MAX_TEXT_BYTES then break end
        cost = cost + encoded
        offset = offset + width
    end
    return math.min(offset - 1, #text)
end
local function bounded(text: string, budget: integer): string
    return text:sub(1, segment_end(text, 1, budget))
end
local function content(text: string): vocabulary.Content
    if #text == 0 then return {text = " "} end
    return {text = text}
end
M.content = content
function M.session(event_key: string, state: string, resume_ref: string?): vocabulary.Observation
    return {type = "session.state", event_key = event_key, data = {type = "session.state", state = state, resume_ref = resume_ref}}
end
function M.turn(event_key: string, phase: string, reported_outcome: string?, usage: {[string]: unknown}?): vocabulary.Observation
    local data: {[string]: unknown} = {type = "turn.signal", phase = phase}
    if reported_outcome then data.reported_outcome = reported_outcome end
    if usage then data.usage = usage end
    return {type = "turn.signal", event_key = event_key, data = data}
end
-- Splits long text into bounded segments so every observation fits a record.
function M.text(event_key: string, segment_id: string, operation: string, text: string, channel: string): {vocabulary.Observation}
    local pieces: {vocabulary.Observation} = {}
    local total = #text
    local offset = 1
    local index = 0
    repeat
        local finish = segment_end(text, offset, M.MAX_ESCAPED_BYTES)
        local piece = text:sub(offset, finish)
        local key = event_key
        if index > 0 then key = event_key .. "#" .. tostring(index) end
        local op = operation
        if index > 0 and operation == "replace" then op = "append" end
        pieces[#pieces + 1] = {type = "text", event_key = key, data = {type = "text", segment_id = segment_id, operation = op, text = piece, channel = channel}}
        offset = finish + 1
        index = index + 1
    until offset > total
    return pieces
end
function M.tool_call(event_key: string, call_id: string, tool_name: string, input: string): vocabulary.Observation
    return {type = "tool.call", event_key = event_key, data = {type = "tool.call", call_id = call_id, tool_name = tool_name, input = content(bounded(input, M.MAX_ESCAPED_BYTES))}}
end
function M.tool_result(event_key: string, call_id: string, outcome: string, output: string, fault: vocabulary.Fault?): vocabulary.Observation
    local data: {[string]: unknown} = {type = "tool.result", call_id = call_id, outcome = outcome, output = content(bounded(output, M.MAX_ESCAPED_BYTES - 2048))}
    if fault then data.error = fault end
    return {type = "tool.result", event_key = event_key, data = data}
end
function M.notice(event_key: string, level: string, code: string, text: string): vocabulary.Observation
    return {type = "notice", event_key = event_key, data = {type = "notice", level = level, code = code, content = content(bounded(text, M.MAX_ESCAPED_BYTES))}}
end
-- A payload beyond the record bound is replaced by a JSON object naming its
-- size; truncating a payload invalidates its JSON.
function M.extension(event_key: string, event_name: string, event_revision: string, payload_json: string): vocabulary.Observation
    local payload = payload_json
    if segment_end(payload, 1, M.MAX_ESCAPED_BYTES) < #payload then payload = '{"omitted_bytes":' .. tostring(#payload_json) .. '}' end
    return {type = "extension", event_key = event_key, data = {type = "extension", event_name = event_name, event_revision = event_revision, payload_json = payload}}
end
-- vocabulary.Usage as the records contract expects it; unknown counters stay absent.
function M.usage(input_tokens: unknown, output_tokens: unknown, cached_tokens: unknown): vocabulary.Usage?
    local input = bounds.count(input_tokens)
    local output = bounds.count(output_tokens)
    local cached = bounds.count(cached_tokens)
    if input == nil and output == nil and cached == nil then return nil end
    return {input_tokens = input, output_tokens = output, cached_tokens = cached}
end
function M.fault(code: string, message: string, retryable: boolean): vocabulary.Fault
    return {code = bounds.id(code) or "unknown", message = bounded(message, 2048), retryable = retryable}
end
-- Decode a fault a provider state record carries; an absent value is
-- (nil, nil) and field names the value in rejections.
function M.decode_fault(value: unknown, field: string, message_limit: integer): (vocabulary.Fault?, string?)
    if value == nil then return nil, nil end
    local object = bounds.object(value)
    if not object then return nil, field .. " must be an object" end
    local unknown_field = bounds.fields(object, {"code", "message", "retryable"})
    if unknown_field then return nil, field .. ": " .. unknown_field end
    local code = bounds.id(object.code)
    if not code then return nil, field .. ".code is not an identifier" end
    local message = bounds.text(object.message, message_limit)
    if not message then return nil, field .. ".message exceeds maximum fault message bytes" end
    if type(object.retryable) ~= "boolean" then return nil, field .. ".retryable must be a boolean" end
    return {code = code, message = message, retryable = object.retryable}, nil
end
return M
