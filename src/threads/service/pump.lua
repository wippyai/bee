-- MIT. The forwarding pump's decisions, pure: what one delivery attempt's
-- reply means for the durable outbox row behind it. A settled delivery is
-- committed on the destination's own reply; a refusal the destination made
-- final fails the row; anything that leaves the outcome unknown is never
-- settled here, so the row's lease lapses and the delivery repeats under
-- the sender's stable idempotency key. Nothing here opens a store, sends a
-- byte or names a policy.
local bounds = require("bounds")
local M = {}
-- One claim never exceeds this many deliveries.
M.BATCH = 16
type Object = {[string]: unknown}
type Outcome = {decision: string, code: string?, message: string?, receipt: unknown?}
type Delivery = {outbox_id: string, thread_id: string, target_action_id: string, sender_thread_id: string,
    sender_action_id: string, node_id: string, workspace_id: string, grant_epoch: integer,
    idempotency_key: string, message_id: string, content: Object, payload_digest: string,
    caller_node_id: string, in_reply_to: {thread_id: string, record_id: string}?, outcome: string?}
-- Reply codes the destination has made final: repeating the identical
-- delivery cannot succeed, so the row fails rather than retrying forever.
local FINAL: {[string]: boolean} = {
    DENIED = true, NOT_FOUND = true, CONFLICT = true, INVALID_ARGUMENT = true, INVALID_STATE = true,
    UNSUPPORTED_CAPABILITY = true, FORBIDDEN = true, UNAUTHENTICATED = true, LIMIT_EXCEEDED = true, SCHEMA_MISMATCH = true,
}
local function dense_list(value: unknown): {unknown}?
    if type(value) ~= "table" then return nil end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil end
        count = count + 1
    end
    if count > M.BATCH then return nil end
    local result: {unknown} = {}
    for index = 1, count do
        local item = (value)[index]
        if item == nil then return nil end
        result[index] = item
    end
    return result
end
function M.claimed(result: unknown): ({Delivery}?, string?)
    local envelope = bounds.object(result)
    if not envelope or type(envelope.ok) ~= "boolean" then return nil, "forwarding pump claim reply is malformed" end
    if envelope.ok == false then
        local message = type(envelope.message) == "string" and envelope.message or "claim failed"
        return nil, "forwarding pump claim failed: " .. message
    end
    local value = bounds.object(envelope.value)
    if not value or bounds.fields(value, {"deliveries"}) then return nil, "forwarding pump claim value is malformed" end
    local raw_deliveries = dense_list(value.deliveries)
    if not raw_deliveries then return nil, "forwarding pump claim deliveries are not a bounded dense list" end
    local deliveries: {Delivery} = {}
    local allowed = {"outbox_id", "thread_id", "target_action_id", "sender_thread_id", "sender_action_id", "node_id", "workspace_id",
        "grant_epoch", "idempotency_key", "message_id", "content", "payload_digest", "caller_node_id", "in_reply_to", "outcome"}
    for index, raw in ipairs(raw_deliveries) do
        local item = bounds.object(raw)
        local outbox_id = item and bounds.id(item.outbox_id)
        local prefix = "claimed delivery " .. tostring(outbox_id or index)
        if not item or bounds.fields(item, allowed) then return nil, prefix .. " has unknown fields" end
        local thread_id = bounds.id(item.thread_id)
        local target_action_id = bounds.id(item.target_action_id)
        local sender_thread_id = bounds.id(item.sender_thread_id)
        local sender_action_id = bounds.id(item.sender_action_id)
        local node_id, workspace_id = bounds.id(item.node_id), bounds.id(item.workspace_id)
        local grant_epoch = bounds.count(item.grant_epoch)
        local idempotency_key, message_id = bounds.id(item.idempotency_key), bounds.id(item.message_id)
        local content = bounds.object(item.content)
        local payload_digest = item.payload_digest
        local caller_node_id = bounds.id(item.caller_node_id)
        if not outbox_id or not thread_id or not target_action_id or not sender_thread_id or not sender_action_id
            or not node_id or not workspace_id or not grant_epoch or grant_epoch < 1 or not idempotency_key
            or not message_id or not content or type(payload_digest) ~= "string" or #payload_digest ~= 64
            or not payload_digest:match("^[0-9a-f]+$") or not caller_node_id then
            return nil, prefix .. " has invalid required fields"
        end
        local correlation: {thread_id: string, record_id: string}? = nil
        if item.in_reply_to ~= nil then
            local raw_correlation = bounds.object(item.in_reply_to)
            local correlation_thread = raw_correlation and bounds.id(raw_correlation.thread_id)
            local record_id = raw_correlation and bounds.id(raw_correlation.record_id)
            if not raw_correlation or bounds.fields(raw_correlation, {"thread_id", "record_id"})
                or not correlation_thread or not record_id then return nil, prefix .. " has invalid reply correlation" end
            correlation = {thread_id = correlation_thread, record_id = record_id}
        end
        local outcome: string? = nil
        if item.outcome ~= nil then
            outcome = bounds.id(item.outcome)
            if not outcome or not correlation then return nil, prefix .. " has invalid reply outcome" end
        end
        deliveries[index] = {outbox_id = outbox_id, thread_id = thread_id, target_action_id = target_action_id,
            sender_thread_id = sender_thread_id, sender_action_id = sender_action_id, node_id = node_id,
            workspace_id = workspace_id, grant_epoch = grant_epoch, idempotency_key = idempotency_key,
            message_id = message_id, content = content, payload_digest = payload_digest, caller_node_id = caller_node_id,
            in_reply_to = correlation, outcome = outcome}
    end
    return deliveries, nil
end
-- outcome: classify one delivery attempt. "delivered" carries the owner's
-- receipt; "failed" carries the final refusal; "unknown" settles nothing.
-- A transport error is always unknown: the destination may have committed.
function M.outcome(reply: unknown, transport_error: unknown): Outcome
    if transport_error ~= nil then
        return {decision = "unknown", code = "UNAVAILABLE", message = tostring(transport_error), receipt = nil}
    end
    local envelope = bounds.object(reply)
    if not envelope then return {decision = "unknown", code = "INVALID_REPLY", message = "destination reply is malformed", receipt = nil} end
    if envelope.ok == true then return {decision = "delivered", code = nil, message = nil, receipt = envelope.value} end
    local fault = bounds.object(envelope.error)
    if not fault then return {decision = "unknown", code = "INVALID_REPLY", message = "destination refusal is malformed", receipt = nil} end
    local code = bounds.id(fault.code) or "INTERNAL"
    local message = type(fault.message) == "string" and (fault.message) or "delivery refused"
    if FINAL[code] then return {decision = "failed", code = code, message = message, receipt = nil} end
    return {decision = "unknown", code = code, message = message, receipt = nil}
end
return M
