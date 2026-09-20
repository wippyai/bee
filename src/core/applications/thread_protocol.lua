-- MIT. Exact application-to-broker thread facade messages. Identity and
-- authority are never operation arguments; the broker supplies them from the
-- authenticated execution and its durable binding.
local bounds = require("bounds")

type Operation = "read" | "post" | "subscribe" | "page" | "ack_page" | "resume" | "unsubscribe"
type Object = {[string]: unknown}
type Request = {version: integer, request_id: string, instance_id: string, launch_token: string,
    execution_generation: integer, operation: Operation, arguments: Object}
type Fault = {code: string, message: string}
type Reply = {version: integer, request_id: string, instance_id: string,
    execution_generation: integer, ok: boolean, value: unknown, error: Fault?}

local M = {}
local MAX_GENERATION = 2147483647

local function operation(value: unknown): Operation?
    if value == "read" or value == "post" or value == "subscribe" or value == "page"
        or value == "ack_page" or value == "resume" or value == "unsubscribe" then return value end
    return nil
end

local function generation(value: unknown): integer?
    if type(value) ~= "number" or value ~= math.floor(value) or value < 1 or value > MAX_GENERATION then return nil end
    return math.floor(value)
end

local function exact(value: Object, allowed: {string}): boolean
    local fields: {[string]: boolean} = {}
    for _, name in ipairs(allowed) do fields[name] = true end
    for key in pairs(value) do if not fields[key] then return false end end
    return true
end

local function required_id(value: unknown): string?
    return bounds.id(value)
end

local function cursor(value: unknown): integer?
    return bounds.cursor(value)
end

local function limit(value: unknown): integer?
    local result = bounds.integer(value)
    if not result or result < 1 or result > bounds.MAX_PAGE_RECORDS then return nil end
    return result
end

local function ids(value: unknown): {string}?
    local result = bounds.ids(value, true)
    return result
end

local function content(value: unknown): Object?
    local object = bounds.object(value)
    if not object or not exact(object, {"text", "artifact_ref"}) then return nil end
    if object.text ~= nil and not bounds.text(object.text, 16384) then return nil end
    if object.artifact_ref ~= nil and not bounds.id(object.artifact_ref) then return nil end
    if object.text == nil and object.artifact_ref == nil then return nil end
    return object
end

local function arguments(op: Operation, value: unknown): Object?
    local object = bounds.object(value)
    if not object then return nil end
    if op == "read" then
        if not exact(object, {"cursor", "limit"}) then return nil end
        if object.cursor ~= nil and not cursor(object.cursor) then return nil end
        if object.limit ~= nil and not limit(object.limit) then return nil end
    elseif op == "post" then
        if not exact(object, {"idempotency_key", "message_id", "message_kind", "recipient_ids",
            "content", "in_reply_to_record_id", "outcome"}) then return nil end
        local kind = bounds.member(object.message_kind, {"request", "progress", "reply", "notification"})
        local recipients = ids(object.recipient_ids)
        if not required_id(object.idempotency_key) or not required_id(object.message_id) or not kind
            or not recipients or not content(object.content) then return nil end
        if object.in_reply_to_record_id ~= nil and not required_id(object.in_reply_to_record_id) then return nil end
        local outcome = object.outcome == nil and nil or bounds.member(object.outcome, {"succeeded", "failed", "cancelled", "uncertain"})
        if object.outcome ~= nil and not outcome then return nil end
        if kind == "reply" and (object.in_reply_to_record_id == nil or not outcome) then return nil end
        if kind ~= "reply" and object.in_reply_to_record_id ~= nil then return nil end
        if kind ~= "reply" and kind ~= "notification" and outcome then return nil end
    elseif op == "subscribe" then
        if not exact(object, {"idempotency_key", "after_sequence"}) or not required_id(object.idempotency_key)
            or not cursor(object.after_sequence) then return nil end
    elseif op == "page" then
        if not exact(object, {"subscription_id", "limit"}) or not required_id(object.subscription_id) then return nil end
        if object.limit ~= nil and not limit(object.limit) then return nil end
    elseif op == "ack_page" then
        if not exact(object, {"idempotency_key", "subscription_id", "page_id", "scanned_through"})
            or not required_id(object.idempotency_key) or not required_id(object.subscription_id)
            or not required_id(object.page_id) or not cursor(object.scanned_through) then return nil end
    else
        if not exact(object, {"idempotency_key", "subscription_id"})
            or not required_id(object.idempotency_key) or not required_id(object.subscription_id) then return nil end
    end
    return object
end

function M.request(value: unknown): Request?
    local object = bounds.object(value)
    if not object or not exact(object, {"version", "request_id", "instance_id", "launch_token",
        "execution_generation", "operation", "arguments"}) or object.version ~= 1 then return nil end
    local request_id = required_id(object.request_id)
    local instance_id = required_id(object.instance_id)
    local launch_token = required_id(object.launch_token)
    local selected = operation(object.operation)
    local current_generation = generation(object.execution_generation)
    if not request_id or not instance_id or not launch_token or not selected or not current_generation then return nil end
    local decoded = arguments(selected, object.arguments)
    if not decoded then return nil end
    return {version = 1, request_id = request_id, instance_id = instance_id, launch_token = launch_token,
        execution_generation = current_generation, operation = selected, arguments = decoded}
end

function M.reply(value: unknown): Reply?
    local object = bounds.object(value)
    if not object or not exact(object, {"version", "request_id", "instance_id", "execution_generation",
        "ok", "value", "error"}) or object.version ~= 1 or type(object.ok) ~= "boolean" then return nil end
    local request_id = required_id(object.request_id)
    local instance_id = required_id(object.instance_id)
    local current_generation = generation(object.execution_generation)
    if not request_id or not instance_id or not current_generation then return nil end
    local failure: Fault? = nil
    if object.ok == false then
        local raw = bounds.object(object.error)
        local code = raw and bounds.id(raw.code)
        local message = raw and bounds.text(raw.message, 4096)
        if not code or not message then return nil end
        failure = {code = code, message = message}
    elseif object.error ~= nil then return nil end
    return {version = 1, request_id = request_id, instance_id = instance_id,
        execution_generation = current_generation, ok = object.ok :: boolean,
        value = object.value, error = failure}
end

return M
