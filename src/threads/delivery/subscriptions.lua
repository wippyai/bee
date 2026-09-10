-- MIT. Subscriptions: a consumer cursor with one outstanding page at a
-- time. A page is a fixed range of the immutable stream; acknowledging it by
-- identity and exact scanned_through is the only way the cursor moves.
-- Nothing here touches recipient obligations.
local sql = require("sql")
local hash = require("hash")
local json = require("json")
local bounds = require("bounds")
local canonical = require("canonical")
local values = require("values")
local record = require("record")
local record_types = require("record_types")
local reader = require("reader")
local transaction = require("transaction")
local owner = require("owner")
local authority = require("authority")
local function record_digest(text: string): (string?, string?)
    local digest, err = hash.sha256(text)
    if err or not digest then return nil, "digest filter" end
    return digest, nil
end
local M = {}
type Result = transaction.Result
type Filter = {kinds: {string}?, action_id: string?}
local SCAN_WINDOW = 1024
-- A thread's subscriptions, open and closed together, are bounded. A closed
-- subscription keeps its durable cursor for resume and still counts toward
-- this bound; capacity is reclaimed only by the owner's explicit
-- forget_subscription, never by silently discarding resumable progress.
M.MAX_THREAD_SUBSCRIPTIONS = 128
local function failure(code: string, message: string): Result
    return transaction.failure(code, message)
end
local function storage(err: string): Result
    if err == "BUSY" then return transaction.storage_failure("thread database is busy") end
    return transaction.failure("INTERNAL", err)
end
-- A normalized filter: sorted distinct kinds and an optional action.
local function decode_filter(value: unknown): (Filter?, string?, string?)
    local filter: Filter = {}
    if value ~= nil then
        local object = bounds.object(value)
        if not object then return nil, nil, "filter must be an object" end
        local unknown_field = bounds.fields(object, {"kinds", "action_id"})
        if unknown_field then return nil, nil, unknown_field end
        if object.kinds ~= nil then
            local list, list_error = bounds.ids(object.kinds, true)
            if not list then return nil, nil, "kinds: " .. tostring(list_error) end
            for _, item in ipairs(list) do
                if not values.kind(item) then return nil, nil, "kinds names an unsupported family" end
            end
            table.sort(list)
            filter.kinds = list
        end
        if object.action_id ~= nil then
            local id = bounds.id(object.action_id)
            if not id then return nil, nil, "action_id is not an identifier" end
            filter.action_id = id
        end
    end
    local encoded, encode_error = canonical.encode({kinds = filter.kinds or {}, action_id = filter.action_id})
    if not encoded then return nil, nil, encode_error end
    return filter, encoded, nil
end
local function subscription_of(tx: sql.Transaction, thread_id: string, value: unknown): (reader.Subscription?, Result?)
    local subscription_id = bounds.id(value)
    if not subscription_id then return nil, failure("INVALID_ARGUMENT", "subscription_id is not an identifier") end
    local subscription, err = reader.subscription(tx, thread_id, subscription_id)
    if err then return nil, storage(err) end
    if not subscription then return nil, failure("NOT_FOUND", "subscription does not exist") end
    return subscription, nil
end
local function summary(tx: sql.Transaction, subscription: reader.Subscription): ({[string]: unknown}?, string?)
    local authority_id, authority_err = owner.authority(tx)
    if authority_err then return nil, authority_err end
    return {subscription_id = subscription.subscription_id, consumer_id = subscription.consumer_id, after_sequence = subscription.after_sequence,
        lease_generation = subscription.lease_generation, owner_incarnation = subscription.owner_incarnation, owner_authority = authority_id, durability = subscription.durability,
        filter_digest = subscription.filter_digest, closed = subscription.closed}, nil
end
function M.subscribe(db: sql.DB, actor: string, request: unknown): Result
    local mutation, invalid = authority.mutation(request)
    if not mutation then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local object = bounds.object(request) or {}
    local unknown_field = bounds.fields(object, {"thread_id", "idempotency_key", "consumer_id", "after_sequence", "filter", "durability"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local consumer_id = bounds.id(object.consumer_id)
    if not consumer_id then return failure("INVALID_ARGUMENT", "consumer_id is not an identifier") end
    local after = bounds.cursor(object.after_sequence)
    if not after then return failure("INVALID_ARGUMENT", "after_sequence must be between 0 and " .. tostring(bounds.MAX_THREAD_RECORDS)) end
    local durability = bounds.member(object.durability, {"durable", "reconstructible"})
    if not durability then return failure("INVALID_ARGUMENT", "durability must be durable or reconstructible") end
    local filter, filter_json, filter_error = decode_filter(object.filter)
    if not filter or not filter_json then return failure("INVALID_ARGUMENT", filter_error or "invalid filter") end
    local digest, digest_error = record_digest(filter_json)
    if not digest then return failure("INTERNAL", digest_error or "digest filter") end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local head, caller, denied = authority.membership(tx, mutation.thread_id, actor)
        if not head or not caller then return denied or failure("DENIED", "caller is not a member of the thread") end
        local replayed, replay_err = authority.replay(tx, actor, "subscribe", mutation)
        if replay_err then return storage(replay_err) end
        if replayed then return replayed end
        local incarnation, incarnation_err = owner.current(tx)
        if incarnation_err then return storage(incarnation_err) end
        if not incarnation then return failure("UNAVAILABLE", "the thread owner has not started") end
        local existing, existing_err = reader.subscription_identity(tx, head.thread_id, actor, consumer_id, digest)
        if existing_err then return storage(existing_err) end
        if existing then return failure("CONFLICT", "an open subscription with this identity exists: " .. existing.subscription_id) end
        local total, count_err = reader.count(tx, "SELECT COUNT(*) AS count FROM bee_thread_subscriptions WHERE thread_id = ?", {head.thread_id}, "subscriptions")
        if not total then return storage(count_err or "count subscriptions") end
        if total >= M.MAX_THREAD_SUBSCRIPTIONS then return failure("LIMIT_EXCEEDED", "thread subscription capacity reached; the owner forgets a closed subscription to reclaim it") end
        local subscription_id, id_err = transaction.record_id()
        if not subscription_id then return failure("INTERNAL", id_err or "allocate subscription identifier") end
        local insert_err = transaction.insert_subscription(tx, subscription_id, head.thread_id, actor, consumer_id, digest, filter_json, durability, after, incarnation, transaction.now())
        if insert_err then return storage(insert_err) end
        local created, created_err = reader.subscription(tx, head.thread_id, subscription_id)
        if not created then return storage(created_err or "read subscription") end
        local view, view_err = summary(tx, created)
        if not view then return storage(view_err or "read owner authority") end
        return authority.remember(tx, actor, "subscribe", mutation, view)
    end)
end
-- Returns the outstanding page, or opens the next one. Pages are fixed
-- ranges of the stream, so a repeated call returns the same records.
function M.page(db: sql.DB, actor: string, request: unknown): Result
    local object = bounds.object(request)
    if not object then return failure("INVALID_ARGUMENT", "request must be an object") end
    local unknown_field = bounds.fields(object, {"thread_id", "subscription_id", "limit"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local thread_id = bounds.id(object.thread_id)
    if not thread_id then return failure("INVALID_ARGUMENT", "thread_id is not an identifier") end
    local limit = bounds.MAX_PAGE_RECORDS
    if object.limit ~= nil then
        local number = bounds.integer(object.limit)
        if not number or number < 1 or number > bounds.MAX_PAGE_RECORDS then return failure("INVALID_ARGUMENT", "limit must be between 1 and " .. tostring(bounds.MAX_PAGE_RECORDS)) end
        limit = number
    end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local head, caller, denied = authority.membership(tx, thread_id, actor)
        if not head or not caller then return denied or failure("DENIED", "caller is not a member of the thread") end
        local subscription, missing = subscription_of(tx, thread_id, object.subscription_id)
        if not subscription then return missing or failure("NOT_FOUND", "subscription does not exist") end
        if subscription.actor ~= actor then return failure("DENIED", "the subscription belongs to another actor") end
        if subscription.closed then return failure("INVALID_STATE", "subscription is closed") end
        local stored: unknown, stored_error = json.decode(subscription.filter)
        if stored_error then return failure("INTERNAL", "stored filter is corrupt") end
        local filter, _, filter_error = decode_filter(stored)
        if not filter then return failure("INTERNAL", filter_error or "stored filter is corrupt") end
        local outstanding, outstanding_err = reader.outstanding_page(tx, subscription.subscription_id)
        if outstanding_err then return storage(outstanding_err) end
        local from = subscription.after_sequence
        local through = 0
        local page_id = ""
        if outstanding then
            from = outstanding.from_sequence
            through = outstanding.scanned_through
            page_id = outstanding.page_id
        else
            through = math.floor(math.min(from + SCAN_WINDOW, head.head_sequence))
            if through <= from then
                return transaction.success({subscription_id = subscription.subscription_id, page_id = nil, records = {}, from_sequence = from, scanned_through = from, has_more = false}, false)
            end
            local allocated, id_err = transaction.record_id()
            if not allocated then return failure("INTERNAL", id_err or "allocate page identifier") end
            page_id = allocated
            local insert_err = transaction.insert_page(tx, page_id, subscription.subscription_id, subscription.lease_generation, from, through, subscription.filter_digest, transaction.now())
            if insert_err then return storage(insert_err) end
        end
        local rows, rows_err = reader.page(tx, thread_id, from, through, limit, filter.kinds, filter.action_id)
        if not rows then return storage(rows_err or "read thread records") end
        local records: {record_types.Record} = {}
        for index = 1, math.min(#rows, limit) do
            local decoded, decode_error = record.decode_json(rows[index].record_json)
            if not decoded then return failure("INTERNAL", decode_error or "stored record is corrupt") end
            records[index] = decoded
        end
        local has_more = #rows > limit
        local scanned = through
        if has_more then
            -- The page ends at the last returned record; the rest stays ahead.
            scanned = records[#records].sequence
            local shrink_err = transaction.set_page_through(tx, page_id, scanned)
            if shrink_err then return storage(shrink_err) end
        end
        return transaction.success({subscription_id = subscription.subscription_id, page_id = page_id, lease_generation = subscription.lease_generation,
            records = records, from_sequence = from, scanned_through = scanned, has_more = has_more or scanned < head.head_sequence}, false)
    end)
end
-- Acknowledges the outstanding page by identity and exact extent.
function M.ack_page(db: sql.DB, actor: string, request: unknown): Result
    local mutation, invalid = authority.mutation(request)
    if not mutation then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local object = bounds.object(request) or {}
    local unknown_field = bounds.fields(object, {"thread_id", "idempotency_key", "subscription_id", "page_id", "scanned_through"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local page_id = bounds.id(object.page_id)
    local through = bounds.cursor(object.scanned_through)
    if not page_id then return failure("INVALID_ARGUMENT", "page_id is not an identifier") end
    if not through then return failure("INVALID_ARGUMENT", "scanned_through is out of range") end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local head, caller, denied = authority.membership(tx, mutation.thread_id, actor)
        if not head or not caller then return denied or failure("DENIED", "caller is not a member of the thread") end
        local replayed, replay_err = authority.replay(tx, actor, "ack_page", mutation)
        if replay_err then return storage(replay_err) end
        if replayed then return replayed end
        local subscription, missing = subscription_of(tx, head.thread_id, object.subscription_id)
        if not subscription then return missing or failure("NOT_FOUND", "subscription does not exist") end
        if subscription.actor ~= actor then return failure("DENIED", "the subscription belongs to another actor") end
        if subscription.closed then return failure("INVALID_STATE", "subscription is closed") end
        local incarnation, incarnation_err = owner.current(tx)
        if incarnation_err then return storage(incarnation_err) end
        if not incarnation or incarnation ~= subscription.owner_incarnation then return failure("CONFLICT", "the subscription belongs to an earlier owner incarnation; resume it") end
        local outstanding, outstanding_err = reader.outstanding_page(tx, subscription.subscription_id)
        if outstanding_err then return storage(outstanding_err) end
        if not outstanding then return failure("INVALID_STATE", "no page is outstanding") end
        if outstanding.page_id ~= page_id then return failure("CONFLICT", "page_id is not the outstanding page") end
        if outstanding.lease_generation ~= subscription.lease_generation then return failure("CONFLICT", "the page belongs to an earlier lease generation") end
        if outstanding.scanned_through ~= through then return failure("CONFLICT", "scanned_through does not match the page") end
        local ack_err = transaction.ack_page(tx, page_id)
        if ack_err then return storage(ack_err) end
        local cursor_err = transaction.set_subscription_cursor(tx, subscription.subscription_id, through)
        if cursor_err then return storage(cursor_err) end
        return authority.remember(tx, actor, "ack_page", mutation, {subscription_id = subscription.subscription_id, after_sequence = through})
    end)
end
local function transition(operation: string, db: sql.DB, actor: string, request: unknown, apply: (sql.Transaction, reader.Subscription, integer) -> Result): Result
    local mutation, invalid = authority.mutation(request)
    if not mutation then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local object = bounds.object(request) or {}
    local unknown_field = bounds.fields(object, {"thread_id", "idempotency_key", "subscription_id"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local head, caller, denied = authority.membership(tx, mutation.thread_id, actor)
        if not head or not caller then return denied or failure("DENIED", "caller is not a member of the thread") end
        local replayed, replay_err = authority.replay(tx, actor, operation, mutation)
        if replay_err then return storage(replay_err) end
        if replayed then return replayed end
        local subscription, missing = subscription_of(tx, head.thread_id, object.subscription_id)
        if not subscription then return missing or failure("NOT_FOUND", "subscription does not exist") end
        if subscription.actor ~= actor then return failure("DENIED", "the subscription belongs to another actor") end
        local incarnation, incarnation_err = owner.current(tx)
        if incarnation_err then return storage(incarnation_err) end
        if not incarnation then return failure("UNAVAILABLE", "the thread owner has not started") end
        local result = apply(tx, subscription, incarnation)
        if not result.ok then return result end
        local updated, updated_err = reader.subscription(tx, head.thread_id, subscription.subscription_id)
        if not updated then return storage(updated_err or "read subscription") end
        local view, view_err = summary(tx, updated)
        if not view then return storage(view_err or "read owner authority") end
        return authority.remember(tx, actor, operation, mutation, view)
    end)
end
function M.unsubscribe(db: sql.DB, actor: string, request: unknown): Result
    return transition("unsubscribe", db, actor, request, function(tx: sql.Transaction, subscription: reader.Subscription, _: integer): Result
        if subscription.closed then return failure("INVALID_STATE", "subscription is already closed") end
        local err = transaction.close_subscription(tx, subscription.subscription_id, transaction.now())
        if err then return storage(err) end
        return transaction.success(nil, false)
    end)
end
-- Rebinds a retained durable consumer: a new lease generation under the
-- current owner incarnation, which fences every earlier page.
function M.resume(db: sql.DB, actor: string, request: unknown): Result
    return transition("resume", db, actor, request, function(tx: sql.Transaction, subscription: reader.Subscription, incarnation: integer): Result
        if subscription.durability ~= "durable" then return failure("INVALID_STATE", "only a durable subscription resumes") end
        local err = transaction.resume_subscription(tx, subscription.subscription_id, subscription.lease_generation + 1, incarnation)
        if err then return storage(err) end
        local pages_err = transaction.retire_pages(tx, subscription.subscription_id)
        if pages_err then return storage(pages_err) end
        return transaction.success(nil, false)
    end)
end
-- The thread owner runs both lifecycle operations against any subscription,
-- so it can retire subscriptions an abandoned consumer never closes. It is
-- authorized by thread ownership, not by holding the subscription.
local function owner_lifecycle(operation: string, db: sql.DB, actor: string, request: unknown,
    apply: (sql.Transaction, string, string, reader.Subscription?) -> Result): Result
    local mutation, invalid = authority.mutation(request)
    if not mutation then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local object = bounds.object(request) or {}
    local unknown_field = bounds.fields(object, {"thread_id", "idempotency_key", "subscription_id"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local subscription_id = bounds.id(object.subscription_id)
    if not subscription_id then return failure("INVALID_ARGUMENT", "subscription_id is not an identifier") end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local head, caller, denied = authority.membership(tx, mutation.thread_id, actor)
        if not head or not caller then return denied or failure("DENIED", "caller is not a member of the thread") end
        if head.owner_actor ~= actor then return failure("DENIED", "only the thread owner may " .. operation .. " a subscription") end
        local replayed, replay_err = authority.replay(tx, actor, operation, mutation)
        if replay_err then return storage(replay_err) end
        if replayed then return replayed end
        local subscription, sub_err = reader.subscription(tx, head.thread_id, subscription_id)
        if sub_err then return storage(sub_err) end
        local result = apply(tx, head.thread_id, subscription_id, subscription)
        if not result.ok then return result end
        return authority.remember(tx, actor, operation, mutation, result.value)
    end)
end
-- close: the owner stops delivery on a subscription while preserving its
-- durable cursor for a later resume. It retires any outstanding page so a
-- late acknowledgment under the old lease is refused, and bounds retained
-- metadata. Idempotent: closing an already closed or absent subscription
-- reports it closed without changing anything.
function M.close_subscription(db: sql.DB, actor: string, request: unknown): Result
    return owner_lifecycle("close_subscription", db, actor, request, function(tx: sql.Transaction, thread_id: string, subscription_id: string, subscription: reader.Subscription?): Result
        if subscription and not subscription.closed then
            local err = transaction.close_subscription(tx, subscription.subscription_id, transaction.now())
            if err then return storage(err) end
            local pages_err = transaction.retire_pages(tx, subscription.subscription_id)
            if pages_err then return storage(pages_err) end
        end
        return transaction.success({subscription_id = subscription_id, closed = true}, false)
    end)
end
-- forget: the owner drops a closed subscription's retained metadata,
-- reclaiming capacity. A subscription must be closed first, so an ordinary
-- detach never loses a cursor. Idempotent: forgetting an absent subscription
-- reports it forgotten; the durable cursor, its lease, outstanding page and
-- any later acknowledgment are gone, so every later call is NOT_FOUND.
function M.forget_subscription(db: sql.DB, actor: string, request: unknown): Result
    return owner_lifecycle("forget_subscription", db, actor, request, function(tx: sql.Transaction, thread_id: string, subscription_id: string, subscription: reader.Subscription?): Result
        if subscription then
            if not subscription.closed then return failure("INVALID_STATE", "close the subscription before forgetting it") end
            local pages_err = transaction.delete_subscription_pages(tx, subscription.subscription_id)
            if pages_err then return storage(pages_err) end
            local del_err = transaction.delete_subscription(tx, subscription.subscription_id)
            if del_err then return storage(del_err) end
        end
        return transaction.success({subscription_id = subscription_id, forgotten = true}, false)
    end)
end
return M
