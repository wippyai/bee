-- MIT. Exact application-to-broker thread facade messages. Identity and
-- authority come from the authenticated execution and its durable binding.
local bounds = require("bounds")
local record = require("record")
local record_types = require("record_types")

type Operation = "read" | "post" | "subscribe" | "page" | "ack_page" | "resume" | "unsubscribe"
type Object = {[string]: unknown}
type Request = {version: integer, request_id: string, instance_id: string, launch_token: string,
    execution_generation: integer, operation: Operation, arguments: Object}
type Identity = {request_id: string, instance_id: string, execution_generation: integer}
type Fault = {code: string, message: string}
type Subscription = {subscription_id: string, consumer_id: string, after_sequence: integer, lease_generation: integer,
    owner_incarnation: integer, owner_authority: string, durability: "durable" | "reconstructible", filter_digest: string, closed: boolean}
type ReadResult = {records: {record_types.Record}, scanned_through: integer, has_more: boolean}
type PostResult = {record_id: string, sequence: integer}
type PageResult = {subscription_id: string, page_id: string?, lease_generation: integer?, records: {record_types.Record},
    from_sequence: integer, scanned_through: integer, has_more: boolean}
type AckPageResult = {subscription_id: string, after_sequence: integer}
type SuccessReply =
    {operation: "read", ok: true, value: ReadResult, error: nil, request_id: string, instance_id: string, execution_generation: integer}
    | {operation: "post", ok: true, value: PostResult, error: nil, request_id: string, instance_id: string, execution_generation: integer}
    | {operation: "subscribe" | "resume" | "unsubscribe", ok: true, value: Subscription, error: nil, request_id: string, instance_id: string, execution_generation: integer}
    | {operation: "page", ok: true, value: PageResult, error: nil, request_id: string, instance_id: string, execution_generation: integer}
    | {operation: "ack_page", ok: true, value: AckPageResult, error: nil, request_id: string, instance_id: string, execution_generation: integer}
type Reply = SuccessReply | {operation: Operation, ok: false, value: nil, error: Fault,
    request_id: string, instance_id: string, execution_generation: integer}

local M = {}
local MAX_GENERATION = 2147483647

function M.operation(value: unknown): Operation?
    if value == "read" then return "read" end
    if value == "post" then return "post" end
    if value == "subscribe" then return "subscribe" end
    if value == "page" then return "page" end
    if value == "ack_page" then return "ack_page" end
    if value == "resume" then return "resume" end
    if value == "unsubscribe" then return "unsubscribe" end
    return nil
end

local function generation(value: unknown): integer?
    local number = bounds.integer(value)
    if not number or number < 1 or number > MAX_GENERATION then return nil end
    return number
end

local function exact(value: Object, allowed: {string}): boolean
    return bounds.fields(value, allowed) == nil
end

local function required_id(value: unknown): string?
    return bounds.id(value)
end

local function cursor(value: unknown): integer?
    return record_bounds.cursor(value)
end

local function limit(value: unknown): integer?
    local result = bounds.integer(value)
    if not result or result < 1 or result > record_bounds.MAX_PAGE_RECORDS then return nil end
    return result
end

local function ids(value: unknown): {string}?
    return bounds.ids(value, true)
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
    local request_id, instance_id, launch_token = required_id(object.request_id), required_id(object.instance_id), required_id(object.launch_token)
    local selected = M.operation(object.operation)
    local current_generation = generation(object.execution_generation)
    if not request_id or not instance_id or not launch_token or not selected or not current_generation then return nil end
    local decoded = arguments(selected, object.arguments)
    if not decoded then return nil end
    return {version = 1, request_id = request_id, instance_id = instance_id, launch_token = launch_token,
        execution_generation = current_generation, operation = selected, arguments = decoded}
end

local function record_list(value: unknown): {record_types.Record}?
    local list = bounds.array(value, record_bounds.MAX_PAGE_RECORDS)
    if not list then return nil end
    local decoded: {record_types.Record} = {}
    for index, item in ipairs(list) do
        local entry = record.decode(item)
        if not entry then return nil end
        decoded[index] = entry
    end
    return decoded
end

local function subscription(value: unknown): Subscription?
    local object = bounds.object(value)
    if not object or not exact(object, {"subscription_id", "consumer_id", "after_sequence", "lease_generation",
        "owner_incarnation", "owner_authority", "durability", "filter_digest", "closed"}) then return nil end
    local subscription_id, consumer_id = bounds.id(object.subscription_id), bounds.id(object.consumer_id)
    local after = record_bounds.cursor(object.after_sequence)
    local lease_generation, incarnation = generation(object.lease_generation), bounds.count(object.owner_incarnation)
    local authority = bounds.id(object.owner_authority)
    local raw_durability = bounds.member(object.durability, {"durable", "reconstructible"})
    local digest = bounds.text(object.filter_digest, 64)
    if not subscription_id or not consumer_id or not after or not lease_generation or not incarnation or not authority
        or not raw_durability or not digest or type(object.closed) ~= "boolean" then return nil end
    local durability: "durable" | "reconstructible"
    if raw_durability == "durable" then durability = "durable"
    elseif raw_durability == "reconstructible" then durability = "reconstructible"
    else return nil end
    return {subscription_id = subscription_id, consumer_id = consumer_id, after_sequence = after,
        lease_generation = lease_generation, owner_incarnation = incarnation, owner_authority = authority,
        durability = durability, filter_digest = digest, closed = object.closed}
end

local function decode_success(op: Operation, value: unknown, identity: Identity): SuccessReply?
    local object = bounds.object(value)
    if not object then return nil end
    if op == "read" then
        if not exact(object, {"records", "scanned_through", "has_more"}) then return nil end
        local records, scanned = record_list(object.records), cursor(object.scanned_through)
        if not records or not scanned or type(object.has_more) ~= "boolean" then return nil end
        local result: ReadResult = {records = records, scanned_through = scanned, has_more = object.has_more}
        local reply: SuccessReply = {operation = "read", ok = true, value = result, error = nil,
            request_id = identity.request_id, instance_id = identity.instance_id, execution_generation = identity.execution_generation}
        return reply
    elseif op == "post" then
        if not exact(object, {"record_id", "sequence"}) then return nil end
        local record_id, sequence = bounds.id(object.record_id), record_bounds.sequence(object.sequence)
        if not record_id or not sequence then return nil end
        local result: PostResult = {record_id = record_id, sequence = sequence}
        local reply: SuccessReply = {operation = "post", ok = true, value = result, error = nil,
            request_id = identity.request_id, instance_id = identity.instance_id, execution_generation = identity.execution_generation}
        return reply
    elseif op == "page" then
        if not exact(object, {"subscription_id", "page_id", "lease_generation", "records", "from_sequence", "scanned_through", "has_more"}) then return nil end
        local subscription_id = bounds.id(object.subscription_id)
        local page_id = object.page_id == nil and nil or bounds.id(object.page_id)
        local lease_generation = object.lease_generation == nil and nil or generation(object.lease_generation)
        local records = record_list(object.records)
        local from, scanned = cursor(object.from_sequence), cursor(object.scanned_through)
        if not subscription_id then return nil end
        if object.page_id ~= nil and not page_id then return nil end
        if object.lease_generation ~= nil and not lease_generation then return nil end
        if (page_id == nil) ~= (lease_generation == nil) then return nil end
        if not records or not from or not scanned or scanned < from then return nil end
        if type(object.has_more) ~= "boolean" then return nil end
        local result: PageResult = {subscription_id = subscription_id, page_id = page_id,
            lease_generation = lease_generation, records = records, from_sequence = from, scanned_through = scanned,
            has_more = object.has_more}
        local reply: SuccessReply = {operation = "page", ok = true, value = result, error = nil, request_id = identity.request_id,
            instance_id = identity.instance_id, execution_generation = identity.execution_generation}
        return reply
    elseif op == "ack_page" then
        if not exact(object, {"subscription_id", "after_sequence"}) then return nil end
        local subscription_id, after = bounds.id(object.subscription_id), cursor(object.after_sequence)
        if not subscription_id or not after then return nil end
        local result: AckPageResult = {subscription_id = subscription_id, after_sequence = after}
        local reply: SuccessReply = {operation = "ack_page", ok = true, value = result, error = nil,
            request_id = identity.request_id, instance_id = identity.instance_id, execution_generation = identity.execution_generation}
        return reply
    end
    local decoded = subscription(value)
    if not decoded then return nil end
    if op == "subscribe" then
        return {operation = "subscribe", ok = true, value = decoded, error = nil, request_id = identity.request_id,
            instance_id = identity.instance_id, execution_generation = identity.execution_generation}
    elseif op == "resume" then
        return {operation = "resume", ok = true, value = decoded, error = nil, request_id = identity.request_id,
            instance_id = identity.instance_id, execution_generation = identity.execution_generation}
    elseif op == "unsubscribe" then
        return {operation = "unsubscribe", ok = true, value = decoded, error = nil, request_id = identity.request_id,
            instance_id = identity.instance_id, execution_generation = identity.execution_generation}
    end
    return nil
end

function M.reply(value: unknown, expected_operation: Operation): Reply?
    local object = bounds.object(value)
    if not object or not exact(object, {"version", "request_id", "instance_id", "execution_generation", "operation", "ok", "value", "error"})
        or object.version ~= 1 or type(object.ok) ~= "boolean" then return nil end
    local request_id, instance_id = required_id(object.request_id), required_id(object.instance_id)
    local operation = M.operation(object.operation)
    local current_generation = generation(object.execution_generation)
    if not request_id or not instance_id or operation ~= expected_operation or not current_generation then return nil end
    if object.ok == false then
        if object.value ~= nil then return nil end
        local raw = bounds.object(object.error)
        if not raw or not exact(raw, {"code", "message"}) then return nil end
        local code, message = bounds.id(raw.code), bounds.text(raw.message, 4096)
        if not code or not message then return nil end
        local decoded: Reply = {operation = operation, ok = false, value = nil, error = {code = code, message = message},
            request_id = request_id, instance_id = instance_id, execution_generation = current_generation}
        return decoded
    end
    if object.error ~= nil then return nil end
    local success = decode_success(operation, object.value,
        {request_id = request_id, instance_id = instance_id, execution_generation = current_generation})
    if not success then return nil end
    return success
end

-- Keep the validated wire envelope when a broker forwards a result. The
-- decoded Reply intentionally drops its version field and must not be sent as
-- a replacement for this message.
function M.wire_reply(value: unknown, expected_operation: Operation): Object?
    if not M.reply(value, expected_operation) then return nil end
    return bounds.object(value)
end

return M
