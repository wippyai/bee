-- MIT. Observation decoder: the tagged data union and its envelope fields.
local json = require("json")
local types = require("types")
local bounds = require("bounds")
local values = require("values")
local M = {}
local function depth(value: unknown, level: integer): integer
    if type(value) ~= "table" then return level end
    local deepest = level
    for _, item in pairs(value) do
        local inner = depth(item, level + 1)
        if inner > deepest then deepest = inner end
        if deepest > bounds.MAX_JSON_DEPTH then return deepest end
    end
    return deepest
end
local function decode_data(value: unknown): (types.ObservationData?, string?)
    local object = bounds.object(value)
    if not object then return nil, "observation data must be an object" end
    local tag: unknown = object.type
    if tag == "session.state" then
        local unknown_field = bounds.fields(object, {"type", "state", "resume_ref"})
        if unknown_field then return nil, unknown_field end
        local state = bounds.member(object.state, {"started", "resumed", "ended"})
        if not state then return nil, "session state is not started, resumed or ended" end
        local resume_ref, valid = values.optional_id(object, "resume_ref")
        if not valid then return nil, "resume_ref is not an identifier" end
        return {type = "session.state", state = state :: types.SessionPhase, resume_ref = resume_ref}, nil
    elseif tag == "turn.signal" then
        local unknown_field = bounds.fields(object, {"type", "phase", "reported_outcome", "usage"})
        if unknown_field then return nil, unknown_field end
        local phase = bounds.member(object.phase, {"submitted", "started", "ended"})
        if not phase then return nil, "turn signal phase is not submitted, started or ended" end
        local signal: types.TurnSignal = {type = "turn.signal", phase = phase :: types.SignalPhase}
        if object.reported_outcome ~= nil then
            local outcome = values.outcome(object.reported_outcome)
            if not outcome then return nil, "reported_outcome is not an outcome" end
            signal.reported_outcome = outcome
        end
        if object.usage ~= nil then
            local usage, usage_error = values.usage(object.usage)
            if not usage then return nil, usage_error end
            signal.usage = usage
        end
        return signal, nil
    elseif tag == "text" then
        local unknown_field = bounds.fields(object, {"type", "segment_id", "operation", "text", "channel"})
        if unknown_field then return nil, unknown_field end
        local segment = bounds.id(object.segment_id)
        local operation = bounds.member(object.operation, {"append", "replace", "complete"})
        local text = bounds.text(object.text)
        local channel = bounds.member(object.channel, {"answer", "progress", "reasoning_summary"})
        if not segment then return nil, "segment_id is not an identifier" end
        if not operation then return nil, "text operation is not append, replace or complete" end
        if not text then return nil, "text is not bounded text" end
        if not channel then return nil, "text channel is not answer, progress or reasoning_summary" end
        return {type = "text", segment_id = segment, operation = operation :: types.TextOperation,
            text = text, channel = channel :: types.TextChannel}, nil
    elseif tag == "tool.call" then
        local unknown_field = bounds.fields(object, {"type", "call_id", "tool_name", "input"})
        if unknown_field then return nil, unknown_field end
        local call_id, tool_name = bounds.id(object.call_id), bounds.id(object.tool_name)
        if not call_id then return nil, "call_id is not an identifier" end
        if not tool_name then return nil, "tool_name is not an identifier" end
        local input, input_error = values.content(object.input)
        if not input then return nil, input_error end
        return {type = "tool.call", call_id = call_id, tool_name = tool_name, input = input}, nil
    elseif tag == "tool.result" then
        local unknown_field = bounds.fields(object, {"type", "call_id", "outcome", "output", "error"})
        if unknown_field then return nil, unknown_field end
        local call_id = bounds.id(object.call_id)
        local outcome = values.outcome(object.outcome)
        if not call_id then return nil, "call_id is not an identifier" end
        if not outcome then return nil, "tool result outcome is not an outcome" end
        local output, output_error = values.content(object.output)
        if not output then return nil, output_error end
        local result: types.ToolResult = {type = "tool.result", call_id = call_id, outcome = outcome, output = output}
        if object.error ~= nil then
            local fault, fault_error = values.fault(object.error)
            if not fault then return nil, fault_error end
            result.error = fault
        end
        return result, nil
    elseif tag == "notice" then
        local unknown_field = bounds.fields(object, {"type", "level", "code", "content"})
        if unknown_field then return nil, unknown_field end
        local level = bounds.member(object.level, {"info", "warning", "error"})
        local code = bounds.id(object.code)
        if not level then return nil, "notice level is not info, warning or error" end
        if not code then return nil, "notice code is not an identifier" end
        local content, content_error = values.content(object.content)
        if not content then return nil, content_error end
        return {type = "notice", level = level :: types.NoticeLevel, code = code, content = content}, nil
    elseif tag == "execution.exit" then
        local unknown_field = bounds.fields(object, {"type", "exit_code", "signal"})
        if unknown_field then return nil, unknown_field end
        local exit: types.ExecutionExit = {type = "execution.exit"}
        if object.exit_code ~= nil then
            local code = bounds.integer(object.exit_code)
            if not code or code < -2147483648 or code > 2147483647 then return nil, "exit_code is not a 32-bit integer" end
            exit.exit_code = code
        end
        local signal, valid = values.optional_id(object, "signal")
        if not valid then return nil, "signal is not an identifier" end
        exit.signal = signal
        return exit, nil
    elseif tag == "extension" then
        local unknown_field = bounds.fields(object, {"type", "event_name", "event_revision", "payload_json"})
        if unknown_field then return nil, unknown_field end
        local name, revision = bounds.id(object.event_name), bounds.id(object.event_revision)
        local payload = bounds.text(object.payload_json)
        if not name or not name:find("%.") then return nil, "event_name must be a namespaced identifier" end
        if not revision then return nil, "event_revision is not an identifier" end
        if not payload or #payload == 0 then return nil, "payload_json is not bounded text" end
        local decoded: unknown, decode_error = json.decode(payload)
        if decode_error then return nil, "payload_json is not valid JSON" end
        if depth(decoded, 1) > bounds.MAX_JSON_DEPTH then return nil, "payload_json nests deeper than " .. tostring(bounds.MAX_JSON_DEPTH) end
        return {type = "extension", event_name = name, event_revision = revision, payload_json = payload}, nil
    end
    return nil, "observation type is not supported"
end
function M.decode(value: unknown): (types.Observation?, string?)
    local object = bounds.object(value)
    if not object then return nil, "observation must be an object" end
    local unknown_field = bounds.fields(object, {"type", "event_key", "observed_at", "external_id", "data", "raw_ref"})
    if unknown_field then return nil, unknown_field end
    local tag, event_key = bounds.id(object.type), bounds.id(object.event_key)
    if not tag then return nil, "observation type is not an identifier" end
    if not event_key then return nil, "event_key is not an identifier" end
    local data, data_error = decode_data(object.data)
    if not data then return nil, data_error end
    if data.type ~= tag then return nil, "observation type does not match its data" end
    local observation: types.Observation = {type = tag, event_key = event_key, data = data}
    if object.observed_at ~= nil then
        local observed = bounds.timestamp(object.observed_at)
        if not observed then return nil, "observed_at is not a canonical UTC timestamp" end
        observation.observed_at = observed
    end
    local external, external_valid = values.optional_id(object, "external_id")
    if not external_valid then return nil, "external_id is not an identifier" end
    observation.external_id = external
    local raw, raw_valid = values.optional_id(object, "raw_ref")
    if not raw_valid then return nil, "raw_ref is not an identifier" end
    observation.raw_ref = raw
    return observation, nil
end
return M
