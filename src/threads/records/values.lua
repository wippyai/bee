-- MIT. Decoders for the shared value types every family embeds.
local types = require("types")
local bounds = require("bounds")
local M = {}
function M.source(value: unknown): types.Source?
    local member = bounds.member(value, bounds.SOURCES)
    if not member then return nil end
    return member :: types.Source
end
function M.outcome(value: unknown): types.Outcome?
    local member = bounds.member(value, bounds.OUTCOMES)
    if not member then return nil end
    return member :: types.Outcome
end
function M.kind(value: unknown): types.Kind?
    local member = bounds.member(value, bounds.KINDS)
    if not member then return nil end
    return member :: types.Kind
end
function M.ref(value: unknown): (types.Ref?, string?)
    local object = bounds.object(value)
    if not object then return nil, "reference must be an object" end
    local unknown_field = bounds.fields(object, {"thread_id", "record_id"})
    if unknown_field then return nil, unknown_field end
    local thread_id, record_id = bounds.id(object.thread_id), bounds.id(object.record_id)
    if not thread_id then return nil, "reference thread_id is not an identifier" end
    if not record_id then return nil, "reference record_id is not an identifier" end
    return {thread_id = thread_id, record_id = record_id}, nil
end
function M.fault(value: unknown): (types.Fault?, string?)
    local object = bounds.object(value)
    if not object then return nil, "fault must be an object" end
    local unknown_field = bounds.fields(object, {"code", "message", "retryable"})
    if unknown_field then return nil, unknown_field end
    local code = bounds.id(object.code)
    local message = bounds.text(object.message, bounds.MAX_FAULT_MESSAGE_BYTES)
    local retryable: unknown = object.retryable
    if not code then return nil, "fault code is not an identifier" end
    if not message then return nil, "fault message is not bounded text" end
    if type(retryable) ~= "boolean" then return nil, "fault retryable must be a boolean" end
    return {code = code, message = message, retryable = retryable}, nil
end
function M.usage(value: unknown): (types.Usage?, string?)
    local object = bounds.object(value)
    if not object then return nil, "usage must be an object" end
    local unknown_field = bounds.fields(object, {"input_tokens", "output_tokens", "cached_tokens", "cost_decimal", "currency"})
    if unknown_field then return nil, unknown_field end
    local usage: types.Usage = {}
    for _, name in ipairs({"input_tokens", "output_tokens", "cached_tokens"}) do
        local raw: unknown = object[name]
        if raw ~= nil then
            local count = bounds.count(raw)
            if not count then return nil, "usage " .. name .. " must be a nonnegative integer" end
            if name == "input_tokens" then usage.input_tokens = count
            elseif name == "output_tokens" then usage.output_tokens = count
            else usage.cached_tokens = count end
        end
    end
    local cost: unknown, currency: unknown = object.cost_decimal, object.currency
    if (cost == nil) ~= (currency == nil) then return nil, "usage cost_decimal and currency come together" end
    if cost ~= nil then
        if type(cost) ~= "string" or not cost:match("^%d+%.?%d*$") or #cost > 40 then return nil, "usage cost_decimal must be a decimal string" end
        if type(currency) ~= "string" or not currency:match("^%u%u%u$") then return nil, "usage currency must be a three-letter code" end
        usage.cost_decimal = cost
        usage.currency = currency
    end
    return usage, nil
end
-- Content names exactly one carrier: inline text or a stored artifact.
function M.content(value: unknown): (types.Content?, string?)
    local object = bounds.object(value)
    if not object then return nil, "content must be an object" end
    local unknown_field = bounds.fields(object, {"text", "artifact_ref"})
    if unknown_field then return nil, unknown_field end
    local text: unknown, artifact: unknown = object.text, object.artifact_ref
    if (text == nil) == (artifact == nil) then return nil, "content needs exactly one of text or artifact_ref" end
    if text ~= nil then
        local bounded = bounds.text(text)
        if not bounded or #bounded == 0 then return nil, "content text must be nonempty bounded text" end
        return {text = bounded}, nil
    end
    local ref = bounds.id(artifact)
    if not ref then return nil, "content artifact_ref is not an identifier" end
    return {artifact_ref = ref}, nil
end
function M.optional_id(object: {[string]: unknown}, name: string): (string?, boolean)
    local raw: unknown = object[name]
    if raw == nil then return nil, true end
    local id = bounds.id(raw)
    if not id then return nil, false end
    return id, true
end
return M
