-- MIT. Decoders for the shared value types every family embeds.
local types = require("types")
local bounds = require("bounds")
local record_bounds = require("record_bounds")
local M = {}
function M.source(value: unknown): types.Source?
    local member = bounds.member(value, record_bounds.SOURCES)
    if member ~= "stream" and member ~= "hook" and member ~= "transcript" and member ~= "mcp" and member ~= "bee" then return nil end
    return member
end
function M.outcome(value: unknown): types.Outcome?
    local member = bounds.member(value, record_bounds.OUTCOMES)
    if member ~= "succeeded" and member ~= "failed" and member ~= "cancelled" and member ~= "uncertain" then return nil end
    return member
end
function M.kind(value: unknown): types.Kind?
    local member = bounds.member(value, record_bounds.KINDS)
    if member ~= "observation" and member ~= "message" and member ~= "action.admitted" and member ~= "attempt.prepared" and member ~= "attempt.started" and member ~= "turn.request" and member ~= "turn.end" and member ~= "receipt" and member ~= "delivery.mark" and member ~= "request.answered" and member ~= "approval.request" and member ~= "approval.transition" then return nil end
    return member
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
    local message = bounds.text(object.message, record_bounds.MAX_FAULT_MESSAGE_BYTES)
    local retryable: unknown = object.retryable
    if not code then return nil, "fault code is not an identifier" end
    if not message then return nil, "fault message is not bounded text" end
    if type(retryable) ~= "boolean" then return nil, "fault retryable must be a boolean" end
    return {code = code, message = message, retryable = retryable}, nil
end
function M.nonnegative(value: unknown): number?
    if type(value) ~= "number" or value ~= value or value < 0 or value > bounds.MAX_SAFE_INTEGER then return nil end
    return value
end
local function usage_fields(value: unknown, models: boolean): (types.Usage?, string?)
    local object = bounds.object(value)
    if not object then return nil, "usage must be an object" end
    local allowed = {"input_tokens", "output_tokens", "cached_tokens", "cache_write_tokens", "reasoning_tokens", "cost_usd", "cost_decimal", "currency"}
    if models then allowed[#allowed + 1] = "models" end
    local unknown_field = bounds.fields(object, allowed)
    if unknown_field then return nil, unknown_field end
    local usage: types.Usage = {}
    for _, name in ipairs({"input_tokens", "output_tokens", "cached_tokens", "cache_write_tokens", "reasoning_tokens"}) do
        if object[name] ~= nil then
            local count = bounds.count(object[name])
            if not count then return nil, "usage " .. name .. " must be a nonnegative integer" end
            usage[name] = count
        end
    end
    if object.cost_usd ~= nil then
        local cost = M.nonnegative(object.cost_usd)
        if not cost then return nil, "usage cost_usd must be a finite nonnegative number" end
        usage.cost_usd = cost
    end
    local cost: unknown, currency: unknown = object.cost_decimal, object.currency
    if (cost == nil) ~= (currency == nil) then return nil, "usage cost_decimal and currency come together" end
    if cost ~= nil then
        if type(cost) ~= "string" or not cost:match("^%d+%.?%d*$") or #cost > 40 then return nil, "usage cost_decimal must be a decimal string" end
        if type(currency) ~= "string" or not currency:match("^%u%u%u$") then return nil, "usage currency must be a three-letter code" end
        usage.cost_decimal, usage.currency = cost, currency
    end
    return usage, nil
end
function M.usage(value: unknown): (types.Usage?, string?)
    local usage, err = usage_fields(value, true)
    if not usage then return nil, err end
    local object = assert(bounds.object(value))
    if object.models ~= nil then
        local models = bounds.object(object.models)
        if not models then return nil, "usage models must be an object" end
        local decoded: {[string]: types.ModelUsage} = {}
        local count = 0
        for model, raw in pairs(models) do
            count = count + 1
            if count > 64 or not bounds.model(model) then return nil, "usage models exceeds its bound or has an invalid model" end
            local item, item_error = usage_fields(raw, false)
            if not item then return nil, "usage models " .. model .. ": " .. tostring(item_error) end
            decoded[model] = item
        end
        usage.models = decoded
    end
    return usage, nil
end
function M.limit_status(value: unknown): types.LimitStatus?
    if value == "allowed" or value == "warning" or value == "rejected" then return value end
    return nil
end
function M.rate_limits(value: unknown): (types.RateLimits?, string?)
    local object = bounds.object(value)
    if not object or bounds.fields(object, {"windows", "overage_status", "overage_disabled_reason", "is_using_overage"}) then return nil, "rate_limits has invalid fields" end
    local windows = bounds.array(object.windows, 64)
    if not windows then return nil, "rate_limits.windows must be a bounded list" end
    local result: types.RateLimits = {windows = {}}
    local seen: {[string]: boolean} = {}
    for _, raw in ipairs(windows) do
        local item = bounds.object(raw)
        if not item or bounds.fields(item, {"window", "utilization", "status", "resets_at"}) then return nil, "rate limit window has invalid fields" end
        local window, status = bounds.id(item.window), M.limit_status(item.status)
        if not window or not status or seen[window] then return nil, "rate limit window identity or status is invalid" end
        seen[window] = true
        local utilization: number? = nil
        if item.utilization ~= nil then
            utilization = M.nonnegative(item.utilization)
            if not utilization or utilization > 1 then return nil, "rate limit utilization must be in 0..1" end
        end
        local resets_at: integer? = nil
        if item.resets_at ~= nil then
            resets_at = bounds.count(item.resets_at)
            if not resets_at then return nil, "rate limit resets_at must be epoch seconds" end
        end
        result.windows[#result.windows + 1] = {window = window, status = status, utilization = utilization, resets_at = resets_at}
    end
    if object.overage_status ~= nil then
        result.overage_status = M.limit_status(object.overage_status)
        if not result.overage_status then return nil, "rate limit overage_status is invalid" end
    end
    if object.overage_disabled_reason ~= nil then
        result.overage_disabled_reason = bounds.id(object.overage_disabled_reason)
        if not result.overage_disabled_reason then return nil, "rate limit overage_disabled_reason is invalid" end
    end
    if object.is_using_overage ~= nil then
        if type(object.is_using_overage) ~= "boolean" then return nil, "rate limit is_using_overage must be boolean" end
        result.is_using_overage = object.is_using_overage
    end
    return result, nil
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
