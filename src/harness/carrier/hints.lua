-- MIT. Approval-transition hint subscription: one checkpointed delivery subscription paged on wake or tick.
local bounds = require("bounds")
local canonical = require("canonical")
local record_types = require("record_types")
local record_values = require("record_values")
local thread_record = require("thread_record")
local checkpoint = require("checkpoint")
local service_reply = require("service_reply")
local carrier_types = require("carrier_types")
local M = {}
local THREADS: string = "bee.threads.binding"
local DELIVERY: string = "bee.threads.binding"
local DELIVERY_PAGE_RECORDS: integer = 64
M.THREADS = THREADS
M.DELIVERY = DELIVERY
M.DELIVERY_PAGE_RECORDS = DELIVERY_PAGE_RECORDS
type IO = carrier_types.IO
type Request = carrier_types.Request
type Session = carrier_types.Session
type Object = {[string]: unknown}
type Context = {threads: string, delivery: string, must: (IO, string, unknown) -> (unknown, string?),
    commit: (IO, Session, {{[string]: unknown}}) -> (boolean, string?), step: (IO, string) -> (),
    thread_call: (IO, Request, string, {[string]: unknown}, string?) -> (unknown, string?),
    write: (IO, Session, string, string) -> (boolean, string?)}
local function reply_of(value: unknown, err: string?): (service_reply.Reply?, string?)
    if err then return nil, err end
    return service_reply.decode(value)
end
type SubscriptionView = {subscription_id: string, after_sequence: integer}
type Acknowledgment = {subscription_id: string, after_sequence: integer}
local function subscription_view(value: unknown, expected_id: string?): (SubscriptionView?, string?)
    local object = bounds.object(value)
    if not object then return nil, "subscription must be an object" end
    local unknown_field = bounds.fields(object, {"subscription_id", "consumer_id", "after_sequence", "lease_generation", "owner_incarnation", "owner_authority",
        "durability", "filter_digest", "closed"})
    local subscription_id, consumer_id = bounds.id(object.subscription_id), bounds.id(object.consumer_id)
    local after_sequence, lease_generation = bounds.count(object.after_sequence), bounds.count(object.lease_generation)
    local owner_incarnation, owner_authority = bounds.count(object.owner_incarnation), bounds.id(object.owner_authority)
    local durability = bounds.member(object.durability, {"durable", "reconstructible"})
    local filter_digest = bounds.text(object.filter_digest, 64)
    if unknown_field then return nil, "subscription: " .. unknown_field end
    if not subscription_id or (expected_id ~= nil and subscription_id ~= expected_id) then return nil, "subscription identifier is malformed" end
    if not consumer_id then return nil, "subscription consumer is malformed" end
    if after_sequence == nil then return nil, "subscription cursor is malformed" end
    if lease_generation == nil or lease_generation < 1 then return nil, "subscription lease generation is malformed" end
    if owner_incarnation == nil or owner_incarnation < 1 then return nil, "subscription owner incarnation is malformed" end
    if not owner_authority then return nil, "subscription owner authority is malformed" end
    if not durability then return nil, "subscription durability is malformed" end
    if not filter_digest or #filter_digest ~= 64 or not filter_digest:match("^[0-9a-f]+$") then return nil, "subscription filter digest is malformed" end
    if type(object.closed) ~= "boolean" then return nil, "subscription closed flag is malformed" end
    return {subscription_id = subscription_id, after_sequence = after_sequence}, nil
end
local function acknowledgment(value: unknown, expected_id: string): (Acknowledgment?, string?)
    local object = bounds.object(value)
    if not object then return nil, "delivery acknowledgment must be an object" end
    local unknown_field = bounds.fields(object, {"subscription_id", "after_sequence"})
    local subscription_id = bounds.id(object.subscription_id)
    local after_sequence = bounds.count(object.after_sequence)
    if unknown_field then return nil, "delivery acknowledgment: " .. unknown_field end
    if subscription_id ~= expected_id then return nil, "delivery acknowledgment subscription is malformed" end
    if after_sequence == nil then return nil, "delivery acknowledgment cursor is malformed" end
    return {subscription_id = subscription_id, after_sequence = after_sequence}, nil
end
type DeliveryPage = {subscription_id: string, page_id: string?, scanned_through: integer, has_records: boolean}
local function delivery_page(value: unknown, expected_subscription: string): (DeliveryPage?, string?)
    local object = bounds.object(value)
    if not object then return nil, "delivery page must be an object" end
    local unknown_field = bounds.fields(object, {"subscription_id", "page_id", "lease_generation", "records", "from_sequence", "scanned_through", "has_more"})
    local subscription_id = bounds.id(object.subscription_id)
    local from_sequence, scanned = bounds.count(object.from_sequence), bounds.count(object.scanned_through)
    local lease_generation = object.lease_generation == nil and nil or bounds.count(object.lease_generation)
    local page_id: string? = nil
    if object.page_id ~= nil then page_id = bounds.id(object.page_id) end
    local records, records_error = bounds.array(object.records, DELIVERY_PAGE_RECORDS)
    if unknown_field then return nil, "delivery page: " .. unknown_field end
    if subscription_id ~= expected_subscription then return nil, "delivery page subscription is invalid" end
    if from_sequence == nil then return nil, "delivery page start cursor is invalid" end
    if scanned == nil or scanned < from_sequence then return nil, "delivery page scanned cursor is invalid" end
    if object.lease_generation ~= nil and (lease_generation == nil or lease_generation < 1) then return nil, "delivery page lease generation is invalid" end
    if object.page_id ~= nil and page_id == nil then return nil, "delivery page identifier is invalid" end
    if not records then return nil, "delivery page records are malformed: " .. tostring(records_error) end
    if type(object.has_more) ~= "boolean" then return nil, "delivery page has_more flag is invalid" end
    local previous = from_sequence
    for index, raw in ipairs(records) do
        local record, record_error = thread_record.decode(raw)
        if not record then return nil, "delivery page records[" .. tostring(index) .. "]: " .. tostring(record_error) end
        if record.sequence <= previous or record.sequence > scanned then return nil, "delivery page records are out of sequence" end
        previous = record.sequence
    end
    if page_id == nil and (#records > 0 or scanned ~= from_sequence) then return nil, "delivery page identity and extent disagree" end
    if page_id ~= nil and scanned == from_sequence then return nil, "delivery page has no scanned extent" end
    if not subscription_id then return nil, "delivery page subscription is invalid" end
    local scanned_through: integer = scanned
    return {subscription_id = subscription_id, page_id = page_id, scanned_through = scanned_through, has_records = #records > 0}, nil
end
local function hints_call(io: IO, target: string, request: unknown): ({[string]: unknown}?, string?, string?)
    local raw, call_error = io.call(target, request)
    local reply, reply_error = reply_of(raw, call_error)
    if not reply then return nil, "INTERNAL", tostring(reply_error) end
    if not reply.ok then
        local fault = reply.error or {code = "INTERNAL", message = "hint operation failed"}
        return nil, fault.code, fault.message
    end
    local value = bounds.object(reply.value)
    if not value then return nil, "INTERNAL", "hint operation returned a non-object value" end
    return value, nil, nil
end
-- open_hints: resume the checkpointed subscription under this carrier's
-- lease, or subscribe afresh.
function M.open_hints(ctx: Context, io: IO, session: Session): string?
    if not session.plan.exchange then return nil end
    local request = session.plan.request
    local key = "launch:" .. request.attempt_id .. ":hints:" .. tostring(session.epoch)
    local existing = session.checkpoint.hint_subscription
    if existing then
        local resumed, resume_code, resume_error = hints_call(io, ctx.delivery .. ":resume", {thread_id = request.thread_id, idempotency_key = key, subscription_id = existing})
        if resumed then
            local view, view_error = subscription_view(resumed, existing)
            if not view then return "delivery resume returned malformed data: " .. tostring(view_error) end
            return nil
        end
        -- A subscription that cannot be resumed is closed before another is
        -- opened, so superseded rows never accumulate.
        local closed, close_code, close_error = hints_call(io, ctx.delivery .. ":unsubscribe", {thread_id = request.thread_id, idempotency_key = key .. ":close", subscription_id = existing})
        if closed then
            local view, view_error = subscription_view(closed, existing)
            if not view then return "delivery unsubscribe returned malformed data: " .. tostring(view_error) end
        elseif close_code ~= "NOT_FOUND" and close_code ~= "INVALID_STATE" and close_code ~= "CONFLICT" then
            return "delivery unsubscribe: " .. tostring(close_code) .. ": " .. tostring(close_error or resume_code or resume_error)
        end
        session.checkpoint.hint_subscription = nil
    end
    -- One consumer identity per attempt: a second open subscription under it
    -- is refused by the owner, which leaves polling as the only source.
    local kinds: {string} = {}
    if session.plan.exchange then kinds[#kinds + 1] = "approval.transition" end
    local created, code, message = hints_call(io, ctx.delivery .. ":subscribe", {thread_id = request.thread_id, idempotency_key = key, consumer_id = "carrier:" .. request.attempt_id,
        after_sequence = 0, filter = {kinds = kinds}, durability = "durable"})
    if not created then
        if code == "CONFLICT" then return nil end
        return tostring(code) .. ": " .. tostring(message)
    end
    local view, view_error = subscription_view(created, nil)
    if not view then return "delivery subscribe returned malformed data: " .. tostring(view_error) end
    session.checkpoint.hint_subscription = view.subscription_id
    local committed, commit_error = ctx.commit(io, session, {})
    if not committed then return commit_error end
    ctx.step(io, "hints_opened")
    return nil
end
-- take_hints: the outstanding or next page; true when it carries any
-- transition, which is the one reason to read the owner now. A lost
-- subscription leaves polling as the only source until the next tick
-- reopens it.
function M.take_hints(ctx: Context, io: IO, session: Session): (boolean, string?)
    local subscription = session.checkpoint.hint_subscription
    if not subscription then return false, nil end
    local request = session.plan.request
    local page, code = hints_call(io, ctx.delivery .. ":page", {thread_id = request.thread_id, subscription_id = subscription, limit = 64})
    if not page then
        if code == "NOT_FOUND" or code == "INVALID_STATE" or code == "DENIED" then session.checkpoint.hint_subscription = nil end
        if code == "INTERNAL" then return false, "delivery page returned malformed data" end
        return false, nil
    end
    local decoded, page_error = delivery_page(page, subscription)
    if not decoded then return false, "delivery page is malformed: " .. tostring(page_error) end
    if decoded.page_id then session.pending_hint = {page_id = decoded.page_id, scanned_through = decoded.scanned_through} end
    return decoded.has_records, nil
end
-- acknowledge_hints: after the hints were processed; an acknowledgment the
-- owner refuses for an earlier incarnation is answered by resuming the
-- subscription under a new lease.
function M.acknowledge_hints(ctx: Context, io: IO, session: Session): (boolean, string?)
    local pending = session.pending_hint
    local subscription = session.checkpoint.hint_subscription
    session.pending_hint = nil
    if not pending or not subscription then return true, nil end
    local request = session.plan.request
    local acknowledged, code = hints_call(io, ctx.delivery .. ":ack_page", {thread_id = request.thread_id, idempotency_key = io.key(), subscription_id = subscription, page_id = pending.page_id, scanned_through = pending.scanned_through})
    if acknowledged then
        local view, view_error = acknowledgment(acknowledged, subscription)
        if not view then return false, "delivery acknowledgment returned malformed data: " .. tostring(view_error) end
        if view.after_sequence ~= pending.scanned_through then return false, "delivery acknowledgment advanced to another cursor" end
        return true, nil
    end
    if code == "CONFLICT" then
        local resumed, _, resume_error = hints_call(io, ctx.delivery .. ":resume", {thread_id = request.thread_id, idempotency_key = io.key(), subscription_id = subscription})
        if resumed then
            local view, view_error = subscription_view(resumed, subscription)
            if not view then return false, "delivery resume returned malformed data: " .. tostring(view_error) end
            return true, nil
        end
        if resume_error then return false, resume_error end
    end
    session.checkpoint.hint_subscription = nil
    return true, nil
end
function M.close_hints(ctx: Context, io: IO, session: Session)
    local subscription = session.checkpoint.hint_subscription
    if not subscription then return end
    local request = session.plan.request
    hints_call(io, ctx.delivery .. ":unsubscribe", {thread_id = request.thread_id, idempotency_key = "launch:" .. request.attempt_id .. ":hints:close:" .. tostring(session.epoch), subscription_id = subscription})
    session.checkpoint.hint_subscription = nil
end

return M
