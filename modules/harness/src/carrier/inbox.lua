-- MIT. Inbox delivery, controller wakeups and their acknowledged input boundary.
local bounds = require("bounds")
local canonical = require("canonical")
local record_types = require("record_types")
local record_values = require("record_values")
local thread_record = require("thread_record")
local checkpoint = require("checkpoint")
local service_reply = require("service_reply")
local carrier_types = require("carrier_types")
local M = {}
local THREADS: string = "bee.threads.service"
local DELIVERY: string = "bee.threads.delivery"
local DELIVERY_PAGE_RECORDS: integer = 64
M.THREADS = THREADS
M.DELIVERY = DELIVERY
M.DELIVERY_PAGE_RECORDS = DELIVERY_PAGE_RECORDS
type IO = carrier_types.IO
type Request = carrier_types.Request
type Session = carrier_types.Session
type Offer = carrier_types.Offer
type Object = {[string]: unknown}
type Context = {threads: string, delivery: string, must: (IO, string, unknown) -> (unknown, string?),
    commit: (IO, Session, {{[string]: unknown}}) -> (boolean, string?), step: (IO, string) -> (),
    thread_call: (IO, Request, string, {[string]: unknown}, string?) -> (unknown, string?),
    write: (IO, Session, string, string) -> (boolean, string?)}
local function reply_of(value: unknown, err: string?): (service_reply.Reply?, string?)
    if err then return nil, err end
    return service_reply.decode(value)
end
type InboxState = "committed" | "offered" | "transport_accepted" | "acknowledged" | "replied"
type DeliveryStatus = InboxState | "undeliverable" | "waiting_for_restart"
type InboxItem = {thread_id: string, inbox_sequence: integer, record_id: string, thread_sequence: integer, payload_digest: string, state: InboxState,
    delivery_status: DeliveryStatus, sender_action_id: string, sender_node_id: string, sender_thread_id: string, message_id: string,
    content: record_types.Content, message_kind: "request" | "progress" | "reply" | "notification", in_reply_to: record_types.Ref?}
type InboxPage = {items: {InboxItem}, has_more: boolean, scanned_through: integer}
local function decode_inbox_offer(value: unknown, expected_thread: string, expected_action: string): (Offer?, string?)
    local item = bounds.object(value)
    if not item then return nil, "inbox offer must be an object" end
    local unknown_field = bounds.fields(item, {"empty", "thread_id", "action_id", "record_id", "inbox_sequence", "payload_digest", "message_id", "message_kind",
        "sender_action_id", "sender_thread_id", "sender_node_id", "content", "in_reply_to", "state", "dispatch", "offer_count"})
    if unknown_field then return nil, "inbox offer: " .. unknown_field end
    if item.empty ~= nil then
        if item.empty ~= true then return nil, "inbox offer empty flag is invalid" end
        if bounds.fields(item, {"empty"}) ~= nil then return nil, "empty inbox offer carries an item" end
        return nil, nil
    end
    local thread_id, action_id = bounds.id(item.thread_id), bounds.id(item.action_id)
    local record_id, digest, message_id = bounds.id(item.record_id), bounds.text(item.payload_digest, 64), bounds.id(item.message_id)
    local sequence, offer_count = bounds.count(item.inbox_sequence), bounds.count(item.offer_count)
    local sender_action, sender_thread, sender_node = bounds.id(item.sender_action_id), bounds.id(item.sender_thread_id), bounds.id(item.sender_node_id)
    local content, content_error = record_values.content(item.content)
    local message_kind = bounds.member(item.message_kind, {"request", "progress", "reply", "notification"})
    local state = bounds.member(item.state, {"offered", "transport_accepted"})
    local in_reply_to: record_types.Ref? = nil
    if item.in_reply_to ~= nil then
        local reference, reference_error = record_values.ref(item.in_reply_to)
        if not reference then return nil, "inbox offer reply reference is malformed: " .. tostring(reference_error) end
        in_reply_to = {thread_id = reference.thread_id, record_id = reference.record_id}
    end
    if not thread_id or thread_id ~= expected_thread then return nil, "inbox offer thread is invalid" end
    if not action_id or action_id ~= expected_action then return nil, "inbox offer action is invalid" end
    if not record_id then return nil, "inbox offer record id is invalid" end
    if digest == nil then return nil, "inbox offer digest is invalid" end
    if #digest ~= 64 or not digest:match("^[0-9a-f]+$") then return nil, "inbox offer digest is invalid" end
    if not message_id then return nil, "inbox offer message id is invalid" end
    if sequence == nil or sequence < 1 or offer_count == nil or offer_count < 1 then return nil, "inbox offer sequence is invalid" end
    if not sender_action or not sender_thread or not sender_node then return nil, "inbox offer sender is invalid" end
    if not content then return nil, "inbox offer content is invalid: " .. tostring(content_error) end
    if not message_kind or not state then return nil, "inbox offer kind or state is invalid" end
    if type(item.dispatch) ~= "boolean" then return nil, "inbox offer dispatch flag is invalid" end
    local valid_kind: "request" | "progress" | "reply" | "notification"
    if message_kind == "request" then valid_kind = "request"
    elseif message_kind == "progress" then valid_kind = "progress"
    elseif message_kind == "reply" then valid_kind = "reply"
    else valid_kind = "notification" end
    local valid_state: "offered" | "transport_accepted"
    if state == "offered" then valid_state = "offered" else valid_state = "transport_accepted" end
    local offer: Offer = {thread_id = thread_id, action_id = action_id, record_id = record_id, inbox_sequence = sequence, payload_digest = digest,
        message_id = message_id, message_kind = valid_kind, sender_action_id = sender_action, sender_thread_id = sender_thread,
        sender_node_id = sender_node, content = content, in_reply_to = in_reply_to, state = valid_state, dispatch = item.dispatch, offer_count = offer_count}
    return offer, nil
end
local function inbox_list_page(value: unknown, limit: integer): (InboxPage?, string?)
    local object = bounds.object(value)
    if not object then return nil, "inbox page must be an object" end
    local unknown_field = bounds.fields(object, {"items", "has_more", "scanned_through"})
    local raw_items, array_error = bounds.array(object.items, limit)
    local scanned = bounds.count(object.scanned_through)
    if unknown_field or not raw_items or type(object.has_more) ~= "boolean" or scanned == nil then
        return nil, "inbox page fields are malformed: " .. tostring(array_error)
    end
    local items: {InboxItem} = {}
    local previous = 0
    for index, raw in ipairs(raw_items) do
        local item = bounds.object(raw)
        if not item then return nil, "inbox page items[" .. tostring(index) .. "] must be an object" end
        local item_field = bounds.fields(item, {"thread_id", "inbox_sequence", "record_id", "thread_sequence", "payload_digest", "state", "delivery_status",
            "sender_action_id", "sender_node_id", "sender_thread_id", "message_id", "content", "message_kind", "in_reply_to"})
        local thread_id, record_id = bounds.id(item.thread_id), bounds.id(item.record_id)
        local sequence, thread_sequence = bounds.count(item.inbox_sequence), bounds.count(item.thread_sequence)
        local digest = bounds.text(item.payload_digest, 64)
        local state = bounds.member(item.state, {"committed", "offered", "transport_accepted", "acknowledged", "replied"})
        local delivery_status = bounds.member(item.delivery_status, {"committed", "offered", "transport_accepted", "acknowledged", "replied", "undeliverable", "waiting_for_restart"})
        local sender_action, sender_node, sender_thread = bounds.id(item.sender_action_id), bounds.id(item.sender_node_id), bounds.id(item.sender_thread_id)
        local message_id = bounds.id(item.message_id)
        local content, content_error = record_values.content(item.content)
        local message_kind = bounds.member(item.message_kind, {"request", "progress", "reply", "notification"})
        local in_reply_to: record_types.Ref? = nil
        if item.in_reply_to ~= nil then
            local reference = bounds.object(item.in_reply_to)
            if not reference then return nil, "inbox page items[" .. tostring(index) .. "] has an invalid reply reference" end
            local reference_fields = bounds.fields(reference, {"thread_id", "record_id"})
            local reference_thread, reference_record = bounds.id(reference.thread_id), bounds.id(reference.record_id)
            if reference_fields or not reference_thread or not reference_record then
                return nil, "inbox page items[" .. tostring(index) .. "] has an invalid reply reference"
            end
            in_reply_to = {thread_id = reference_thread, record_id = reference_record}
        end
        if item_field or not thread_id or not record_id or sequence == nil or sequence < 1 or thread_sequence == nil or thread_sequence < 1
            or not digest or #digest ~= 64 or not digest:match("^[0-9a-f]+$") or not state or not delivery_status or not sender_action or not sender_node
            or not sender_thread or not message_id or not content or not message_kind then
            return nil, "inbox page items[" .. tostring(index) .. "] is malformed: " .. tostring(content_error)
        end
        if sequence <= previous or sequence > scanned then return nil, "inbox page items are out of sequence" end
        previous = sequence
        items[index] = {thread_id = thread_id, inbox_sequence = sequence, record_id = record_id, thread_sequence = thread_sequence,
            payload_digest = digest, state = state, delivery_status = delivery_status, sender_action_id = sender_action,
            sender_node_id = sender_node, sender_thread_id = sender_thread, message_id = message_id, content = content,
            message_kind = message_kind, in_reply_to = in_reply_to}
    end
    if #items > 0 and items[#items].inbox_sequence ~= scanned then return nil, "inbox page cursor does not match its final item" end
    return {items = items, has_more = object.has_more, scanned_through = scanned}, nil
end
local function inbox_transport(value: unknown, record_id: string, sequence: integer): (boolean, string?)
    local object = bounds.object(value)
    if not object then return false, "inbox transport result must be an object" end
    local unknown_field = bounds.fields(object, {"record_id", "inbox_sequence", "state"})
    local returned_record, returned_sequence = bounds.id(object.record_id), bounds.count(object.inbox_sequence)
    local state = bounds.member(object.state, {"transport_accepted", "acknowledged", "replied"})
    if unknown_field or returned_record ~= record_id or returned_sequence ~= sequence or not state then
        return false, "inbox transport result is malformed or names another item"
    end
    return true, nil
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
-- lease, or subscribe afresh; returns the cursor to register wakeups from.
function M.open_hints(ctx: Context, io: IO, session: Session): (integer?, string?)
    if not session.plan.exchange and not session.plan.policy.inbox_push then return nil, nil end
    local request = session.plan.request
    local key = "launch:" .. request.attempt_id .. ":hints:" .. tostring(session.epoch)
    local existing = session.checkpoint.hint_subscription
    if existing then
        local resumed, resume_code, resume_error = hints_call(io, ctx.delivery .. ":resume", {thread_id = request.thread_id, idempotency_key = key, subscription_id = existing})
        if resumed then
            local view, view_error = subscription_view(resumed, existing)
            if not view then return nil, "delivery resume returned malformed data: " .. tostring(view_error) end
            return view.after_sequence, nil
        end
        -- A subscription that cannot be resumed is closed before another is
        -- opened, so superseded rows never accumulate.
        local closed, close_code, close_error = hints_call(io, ctx.delivery .. ":unsubscribe", {thread_id = request.thread_id, idempotency_key = key .. ":close", subscription_id = existing})
        if closed then
            local view, view_error = subscription_view(closed, existing)
            if not view then return nil, "delivery unsubscribe returned malformed data: " .. tostring(view_error) end
        elseif close_code ~= "NOT_FOUND" and close_code ~= "INVALID_STATE" and close_code ~= "CONFLICT" then
            return nil, "delivery unsubscribe: " .. tostring(close_code) .. ": " .. tostring(close_error or resume_code or resume_error)
        end
        session.checkpoint.hint_subscription = nil
    end
    -- One consumer identity per attempt: a second open subscription under it
    -- is refused by the owner, which leaves polling as the only source.
    local kinds: {string} = {}
    if session.plan.exchange then kinds[#kinds + 1] = "approval.transition" end
    if session.plan.policy.inbox_push then kinds[#kinds + 1] = "message" end
    local created, code, message = hints_call(io, ctx.delivery .. ":subscribe", {thread_id = request.thread_id, idempotency_key = key, consumer_id = "carrier:" .. request.attempt_id,
        after_sequence = 0, filter = {kinds = kinds}, durability = "durable"})
    if not created then
        if code == "CONFLICT" then return nil, nil end
        return nil, tostring(code) .. ": " .. tostring(message)
    end
    local view, view_error = subscription_view(created, nil)
    if not view then return nil, "delivery subscribe returned malformed data: " .. tostring(view_error) end
    session.checkpoint.hint_subscription = view.subscription_id
    local committed, commit_error = ctx.commit(io, session, {})
    if not committed then return nil, commit_error end
    ctx.step(io, "hints_opened")
    return view.after_sequence, nil
end
-- take_hints: the outstanding or next page; true when it carries any
-- transition, which is the one reason to read the owner now. A lost
-- subscription leaves polling as the only source until the next tick
-- reopens it.
function M.take_hints(ctx: Context, io: IO, session: Session): (boolean, integer?, string?)
    local subscription = session.checkpoint.hint_subscription
    if not subscription then return false, nil, nil end
    local request = session.plan.request
    local page, code = hints_call(io, ctx.delivery .. ":page", {thread_id = request.thread_id, subscription_id = subscription, limit = 64})
    if not page then
        if code == "NOT_FOUND" or code == "INVALID_STATE" or code == "DENIED" then session.checkpoint.hint_subscription = nil end
        if code == "INTERNAL" then return false, nil, "delivery page returned malformed data" end
        return false, nil, nil
    end
    local decoded, page_error = delivery_page(page, subscription)
    if not decoded then return false, nil, "delivery page is malformed: " .. tostring(page_error) end
    if decoded.page_id then session.pending_hint = {page_id = decoded.page_id, scanned_through = decoded.scanned_through} end
    return decoded.has_records, decoded.scanned_through, nil
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
-- The inbox owner returns at most its oldest outstanding item. Rechecking on
-- every wake and bounded tick also catches a signal lost before registration.
function M.offer_inbox(ctx: Context, io: IO, session: Session): (Offer?, string?)
    if not session.plan.policy.inbox_push then return nil, nil end
    local request = session.plan.request
    local value, err = ctx.must(io, ctx.threads .. ":inbox_offer", {thread_id = request.thread_id, action_id = request.action_id,
        attempt_id = request.attempt_id, carrier_epoch = session.epoch})
    if err then return nil, err end
    return decode_inbox_offer(value, request.thread_id, request.action_id)
end
-- inbox_prompt: the identified prompt naming one inbox item, shared by the
-- Claude controller push line and the bounded-driver attempt brief. The
-- offer count travels only where an offer was made.
type InboxPromptItem = {thread_id: string, action_id: string, record_id: string, inbox_sequence: integer, offer_count: integer?,
    payload_digest: string, message_id: string, message_kind: "request" | "progress" | "reply" | "notification", sender_action_id: string, sender_thread_id: string,
    sender_node_id: string, content: record_types.Content, in_reply_to: record_types.Ref?}
function M.inbox_prompt(item: InboxPromptItem): (string?, string?)
    local context: Object = {thread_id = item.thread_id, action_id = item.action_id, record_id = item.record_id, inbox_sequence = item.inbox_sequence,
        payload_digest = item.payload_digest,
        message_id = item.message_id, message_kind = item.message_kind, sender_action_id = item.sender_action_id,
        sender_thread_id = item.sender_thread_id, sender_node_id = item.sender_node_id, content = item.content}
    if item.offer_count then context.offer_count = item.offer_count end
    if item.in_reply_to then context.in_reply_to = item.in_reply_to end
    local encoded, encode_error = canonical.encode(context)
    if not encoded then return nil, encode_error end
    return "Bee action inbox item. Handle this record once. Use session_ack with inbox_sequence, or session_reply to the sender with in_reply_to naming this thread_id and record_id. " .. encoded, nil
end
function M.push_line(item: Offer): (string?, string?)
    local prompt, prompt_error = M.inbox_prompt({thread_id = item.thread_id, action_id = item.action_id, record_id = item.record_id,
        inbox_sequence = item.inbox_sequence, offer_count = item.offer_count, payload_digest = item.payload_digest,
        message_id = item.message_id, message_kind = item.message_kind, sender_action_id = item.sender_action_id,
        sender_thread_id = item.sender_thread_id, sender_node_id = item.sender_node_id, content = item.content, in_reply_to = item.in_reply_to})
    if not prompt then return nil, prompt_error end
    local line, line_error = canonical.encode({type = "user", message = {role = "user", content = prompt}})
    if not line then return nil, line_error end
    if #line + 1 > checkpoint.MAX_PENDING_WRITE_BYTES then return nil, "inbox item exceeds the controller input bound" end
    return line .. "\n", nil
end
-- carry_brief: for a fresh structured attempt on a driver without a
-- between-turns controller, prepend the oldest outstanding inbox item to
-- the brief, so the new attempt starts carrying it. Claude keeps its
-- controller push, windows keep their hook boundary, and resumed attempts
-- keep their provider session: no fixture proves inbox-carry combined
-- with any of those, so none of them is augmented. A read failure or a
-- missing action leaves the brief alone; delivery still waits in
-- session_inbox. The carry is idempotent, so planning the same request
-- twice never prefixes twice.
M.INBOX_CARRY_LIST_LIMIT = 8
M.INBOX_CARRY_EXCERPT_BYTES = 4096
M.BRIEF_BYTES = 16384
local function carry_text(content: unknown): string
    local object = bounds.object(content)
    if object then
        local text = bounds.text(object.text)
        if text then return text end
    end
    local encoded = canonical.encode(content)
    if encoded then return encoded end
    return "undecodable inbox content"
end
function M.carry_brief(ctx: Context, io: IO, request: Request, driver_id: string, mode: string): string
    local brief = request.brief
    if driver_id == "claude" or mode == "window" then return brief end
    if request.previous_attempt_id ~= nil or request.session_ref ~= nil then return brief end
    local page, list_error = ctx.must(io, ctx.threads .. ":inbox_list", {thread_id = request.thread_id, action_id = request.action_id,
        after_sequence = 0, limit = M.INBOX_CARRY_LIST_LIMIT})
    if list_error then return brief end
    local inbox = inbox_list_page(page, M.INBOX_CARRY_LIST_LIMIT)
    if not inbox then return brief end
    local oldest: InboxItem? = nil
    for _, item in ipairs(inbox.items) do
        if item.thread_id ~= request.thread_id then return brief end
        if item.state ~= "acknowledged" and item.state ~= "replied" then oldest = item; break end
    end
    if not oldest then return brief end
    if brief:find(oldest.record_id, 1, true) then return brief end
    local excerpt = carry_text(oldest.content)
    local room = M.BRIEF_BYTES - #brief - 1 - 700
    local capped = math.min(room, M.INBOX_CARRY_EXCERPT_BYTES)
    local carried: record_types.Content = oldest.content
    if capped < #excerpt then
        if capped > 128 then
            carried = {text = excerpt:sub(1, capped - 128) .. "...[truncated; read the full item with session_inbox]"}
        else
            carried = {text = "[content omitted: exceeds the brief bound; read the full item with session_inbox]"}
        end
    end
    local prompt, prompt_error = M.inbox_prompt({thread_id = request.thread_id, action_id = request.action_id, record_id = oldest.record_id,
        inbox_sequence = oldest.inbox_sequence, payload_digest = oldest.payload_digest, message_id = oldest.message_id, message_kind = oldest.message_kind,
        sender_action_id = oldest.sender_action_id, sender_thread_id = oldest.sender_thread_id, sender_node_id = oldest.sender_node_id,
        content = carried, in_reply_to = oldest.in_reply_to})
    if not prompt then return brief end
    if #prompt + 1 + #brief > M.BRIEF_BYTES then return brief end
    return prompt .. "\n" .. brief
end
-- A second Claude turn is admitted before its user line is written. The
-- previous terminal remains in the checkpoint while idle, so recovery can
-- distinguish a completed turn from one awaiting its result.
function M.begin_push_turn(ctx: Context, io: IO, session: Session, item: Offer): (string?, string?)
    if not session.plan.policy.inbox_push or not item.dispatch then return nil, "inbox item is not dispatchable" end
    local turn_prefix = "turn:" .. session.plan.request.attempt_id .. ":inbox:" .. tostring(item.inbox_sequence) .. ":"
    if session.turn_open and session.turn_id:sub(1, #turn_prefix) ~= turn_prefix then
        return nil, "a different turn is still open"
    end
    if session.exit or not session.runner then return nil, "inbox controller has no live runner" end
    local line, line_error = M.push_line(item)
    if not line then return nil, line_error end
    if not session.turn_open then
        session.terminal = nil
        session.checkpoint.terminal = nil
        session.stream_ended = false
        session.checkpoint.stream_ended = nil
        session.normalizer = nil
        session.checkpoint.normalizer_state = nil
        local cleared, clear_error = ctx.commit(io, session, {})
        if not cleared then return nil, clear_error end
        local turn_id = turn_prefix .. tostring(item.offer_count)
        local request = session.plan.request
        local _, turn_error = ctx.thread_call(io, request, "request_turn", {action_id = request.action_id, attempt_id = request.attempt_id,
            turn_id = turn_id, carrier_epoch = session.epoch,
            turn = {input_message_ids = {item.message_id}, input = {text = line}, delivery_ids = {}}}, "inbox-turn:" .. item.record_id .. ":" .. tostring(item.offer_count))
        if turn_error then return nil, turn_error end
        session.turn_id = turn_id
        session.turn_open = true
    end
    local write_id = "inbox:" .. item.record_id .. ":" .. tostring(item.inbox_sequence) .. ":" .. tostring(session.epoch)
    local written, write_error = ctx.write(io, session, write_id, line)
    if not written then return nil, write_error end
    return write_id, nil
end
function M.accept_write(ctx: Context, io: IO, session: Session, write_id: string): (boolean, string?)
    if write_id:sub(1, 6) ~= "inbox:" then return true, nil end
    local record_id, sequence_text = write_id:match("^inbox:(.+):(%d+):%d+$")
    if not record_id or not sequence_text then return false, "malformed inbox write id" end
    local sequence_number = tonumber(sequence_text)
    local sequence = bounds.count(sequence_number)
    if not sequence or sequence < 1 then return false, "malformed inbox write id" end
    local after_sequence = bounds.integer((sequence_number or 1) - 1)
    if after_sequence == nil then return false, "malformed inbox write id" end
    local request = session.plan.request
    local page, read_error = ctx.must(io, ctx.threads .. ":inbox_list", {thread_id = request.thread_id, action_id = request.action_id,
        after_sequence = after_sequence, limit = 1})
    if read_error then return false, read_error end
    local inbox, page_error = inbox_list_page(page, 1)
    if not inbox then return false, "inbox list returned malformed data: " .. tostring(page_error) end
    local item = inbox.items[1]
    if not item or item.thread_id ~= request.thread_id or item.record_id ~= record_id or item.inbox_sequence ~= sequence then
        return false, "inbox write no longer names its record"
    end
    if item.state == "acknowledged" or item.state == "replied" then return true, nil end
    local transported, transport_error = ctx.must(io, ctx.threads .. ":inbox_transport", {thread_id = request.thread_id, action_id = request.action_id,
        attempt_id = request.attempt_id, carrier_epoch = session.epoch, inbox_sequence = sequence, record_id = record_id})
    if transport_error then return false, transport_error end
    return inbox_transport(transported, record_id, sequence)
end

return M
