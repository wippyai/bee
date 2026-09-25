-- MIT. The action inbox is owned by the destination thread. A send never
-- enrolls its actor as a member and never confers thread read authority.
local sql = require("sql")
local system = require("system")
local bounds = require("bounds")
local access = require("access")
local message = require("message")
local record = require("record")
local reader = require("reader")
local transaction = require("transaction")
local authority = require("authority")
local sends = require("sends")
local M = {}
type Result = transaction.Result
type Object = {[string]: unknown}
type InboxRow = {[string]: unknown}
local MAX_ITEMS = 2048
local MAX_PAGE = 64
local function failure(code: string, detail: string): Result return transaction.failure(code, detail) end
local function storage(detail: string): Result return transaction.storage_failure(detail) end
local function rows(tx: sql.Transaction, statement: string, params: {unknown}): ({InboxRow}?, Result?)
    local found, err = tx:query(statement, params)
    if err or not found then return nil, storage("read action inbox") end
    return found :: {InboxRow}, nil
end
local function execute(tx: sql.Transaction, statement: string, params: {unknown}): Result?
    local _, err = tx:execute(statement, params)
    if err then return storage("write action inbox") end
    return nil
end
local function node(): string
    local native, err = system.node.id()
    if err or not native or native == "" then return "local" end
    return native
end
local function address(workspace_id: string, node_id: string, action_id: string): string
    return workspace_id .. "/" .. node_id .. "/" .. action_id
end
local function principal(tx: sql.Transaction, thread_id: string, action_id: string): (string?, Result?)
    local action, action_err = reader.action(tx, thread_id, action_id)
    if action_err then return nil, storage(action_err) end
    if not action then return nil, failure("NOT_FOUND", "action does not exist on the named thread") end
    local admission, admission_err = reader.record(tx, thread_id, action.admitted_record_id)
    if admission_err then return nil, storage(admission_err) end
    if not admission then return nil, failure("INTERNAL", "action admission is missing") end
    local decoded, decode_err = record.decode_json(admission.record_json)
    if not decoded then return nil, failure("INTERNAL", decode_err or "action admission is corrupt") end
    local body = decoded.body :: {principal_id: string}
    return body.principal_id, nil
end
local function target(tx: sql.Transaction, thread_id: string, action_id: string): (reader.Head?, string?, Result?)
    local head, head_err = reader.head(tx, thread_id)
    if head_err then return nil, nil, storage(head_err) end
    if not head then return nil, nil, failure("NOT_FOUND", "thread does not exist") end
    local owner, refused = principal(tx, thread_id, action_id)
    if not owner then return nil, nil, refused end
    return head, owner, nil
end
local function delivery_block(tx: sql.Transaction, thread_id: string, action_id: string): (string?, Result?)
    local action, action_err = reader.action(tx, thread_id, action_id)
    if action_err or not action then return nil, storage(action_err or "read target action") end
    if action.state == "ended" then return "undeliverable", nil end
    local live, live_err = reader.running_attempt(tx, thread_id, action_id)
    if live_err then return nil, storage(live_err) end
    if not live then return "waiting_for_restart", nil end
    return nil, nil
end
local function delivery_status(item: InboxRow): string
    local state = tostring(item.state)
    if state == "acknowledged" or state == "replied" then return state end
    return type(item.delivery_block) == "string" and item.delivery_block :: string or state
end
-- Lifecycle receipts and inbox status commit in the same owner transaction.
-- A late carrier can no longer claim a settled attempt; an unacknowledged
-- item keeps its receipt state but tells senders what delivery now needs.
function M.attempt_ended(tx: sql.Transaction, thread_id: string, action_id: string): Result?
    return execute(tx, "UPDATE bee_thread_inbox_items SET delivery_block = 'waiting_for_restart' " ..
        "WHERE thread_id = ? AND action_id = ? AND state NOT IN ('acknowledged','replied')", {thread_id, action_id})
end
function M.action_ended(tx: sql.Transaction, thread_id: string, action_id: string): Result?
    return execute(tx, "UPDATE bee_thread_inbox_items SET delivery_block = 'undeliverable' " ..
        "WHERE thread_id = ? AND action_id = ? AND state NOT IN ('acknowledged','replied')", {thread_id, action_id})
end
local function own_action(tx: sql.Transaction, actor: string, thread_id: string, action_id: string): (reader.Head?, Result?)
    local head, principal_id, refused = target(tx, thread_id, action_id)
    if not head then return nil, refused end
    if principal_id ~= actor then return nil, failure("DENIED", "action is not admitted for caller") end
    if not head.workspace_id or head.workspace_id ~= access.workspace() then return nil, failure("DENIED", "action is outside caller workspace") end
    return head, nil
end
local function epoch(tx: sql.Transaction, thread_id: string, action_id: string): (integer, Result?)
    local found, refused = rows(tx, "SELECT grant_epoch FROM bee_thread_inbox_epochs WHERE thread_id = ? AND action_id = ?", {thread_id, action_id})
    if not found then return 0, refused end
    if #found == 0 then return 0, nil end
    return math.floor(tonumber(found[1].grant_epoch) or 0), nil
end
function M.accept(db: sql.DB, actor: string, request: unknown): Result
    local mutation, invalid = authority.mutation(request)
    if not mutation then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local object = bounds.object(request) or {}
    local extra = bounds.fields(object, {"thread_id", "idempotency_key", "action_id", "sender_id", "sender_class", "allow", "expected_epoch"})
    if extra then return failure("INVALID_ARGUMENT", extra) end
    local action_id = bounds.id(object.action_id)
    local sender_id = bounds.id(object.sender_id)
    local sender_class = bounds.id(object.sender_class)
    local expected = bounds.integer(object.expected_epoch)
    if not action_id or (sender_id == nil) == (sender_class == nil) or type(object.allow) ~= "boolean" or not expected or expected < 0 then
        return failure("INVALID_ARGUMENT", "action, one sender identity, allow and expected_epoch are required")
    end
    local kind, value = sender_id and "actor" or "class", sender_id or sender_class or ""
    return transaction.write(db, function(tx: sql.Transaction): Result
        local head, member, denied = authority.membership(tx, mutation.thread_id, actor)
        if not head or not member then return denied or failure("DENIED", "caller is not a member") end
        if member.role ~= "owner" then return failure("DENIED", "only thread owner sets inbox acceptance") end
        local replayed, replay_err = authority.replay(tx, actor, "inbox_accept", mutation)
        if replay_err then return storage(replay_err) end
        if replayed then return replayed end
        if head.state ~= "open" then return failure("INVALID_STATE", "thread is closed") end
        local recipient, recipient_err = principal(tx, mutation.thread_id, action_id :: string)
        if not recipient then return recipient_err or failure("NOT_FOUND", "action is missing") end
        local current, current_err = epoch(tx, mutation.thread_id, action_id :: string)
        if current_err then return current_err end
        if current ~= expected then return failure("CONFLICT", "grant epoch is stale") end
        local existing, existing_err = rows(tx, "SELECT sender_value FROM bee_thread_inbox_rules WHERE thread_id = ? AND action_id = ? AND sender_kind = ? AND sender_value = ?",
            {mutation.thread_id, action_id, kind, value})
        if not existing then return existing_err or storage("read acceptance") end
        local changes = (object.allow == true and #existing == 0) or (object.allow == false and #existing > 0)
        local next_epoch: integer = math.floor(tonumber(current) or 0)
        if changes then
            next_epoch = next_epoch + 1
            if current == 0 then
                local err = execute(tx, "INSERT INTO bee_thread_inbox_epochs (thread_id, action_id, grant_epoch) VALUES (?, ?, ?)", {mutation.thread_id, action_id, next_epoch})
                if err then return err end
            else
                local err = execute(tx, "UPDATE bee_thread_inbox_epochs SET grant_epoch = ? WHERE thread_id = ? AND action_id = ?", {next_epoch, mutation.thread_id, action_id})
                if err then return err end
            end
            if object.allow == true then
                local err = execute(tx, "INSERT INTO bee_thread_inbox_rules (thread_id, action_id, sender_kind, sender_value) VALUES (?, ?, ?, ?)", {mutation.thread_id, action_id, kind, value})
                if err then return err end
            else
                local err = execute(tx, "DELETE FROM bee_thread_inbox_rules WHERE thread_id = ? AND action_id = ? AND sender_kind = ? AND sender_value = ?",
                    {mutation.thread_id, action_id, kind, value})
                if err then return err end
            end
        end
        return authority.remember(tx, actor, "inbox_accept", mutation, {action_id = action_id, grant_epoch = next_epoch, accepted = object.allow})
    end)
end
function M.describe(db: sql.DB, actor: string, request: unknown): Result
    local object = bounds.object(request)
    if not object then return failure("INVALID_ARGUMENT", "request must be an object") end
    local extra = bounds.fields(object, {"thread_id", "action_id", "node_id", "attempt_id"})
    if extra then return failure("INVALID_ARGUMENT", extra) end
    local thread_id, action_id, node_id = bounds.id(object.thread_id), bounds.id(object.action_id), bounds.id(object.node_id)
    if not thread_id or not action_id or not node_id then return failure("INVALID_ARGUMENT", "thread, action and node address are required") end
    local attempt_id: string? = nil
    if object.attempt_id ~= nil then
        attempt_id = bounds.id(object.attempt_id)
        if not attempt_id then return failure("INVALID_ARGUMENT", "attempt_id is not an identifier") end
    end
    return transaction.read(db, function(tx: sql.Transaction): Result
        local head, owner, refused = target(tx, thread_id, action_id)
        if not head then return refused or failure("NOT_FOUND", "target unavailable") end
        if node_id ~= node() or not head.workspace_id or head.workspace_id ~= access.workspace() then return failure("NOT_FOUND", "target unavailable") end
        local resource = address(head.workspace_id :: string, node_id, action_id)
        if actor ~= owner and not access.may_discover(resource) then return failure("DENIED", "target is not discoverable") end
        local current, current_err = epoch(tx, thread_id, action_id)
        if current_err then return current_err end
        local state = "unstarted"
        if attempt_id then
            local attempt, attempt_err = reader.attempt(tx, thread_id, attempt_id)
            if attempt_err then return storage(attempt_err) end
            if not attempt or attempt.action_id ~= action_id then return failure("NOT_FOUND", "attempt is not on target action") end
            state = attempt.state
        end
        local latest, latest_err = rows(tx, "SELECT state, delivery_block, inbox_sequence FROM bee_thread_inbox_items WHERE thread_id = ? AND action_id = ? ORDER BY inbox_sequence DESC LIMIT 1", {thread_id, action_id})
        if not latest then return latest_err or storage("read latest inbox state") end
        return transaction.success({node_id = node_id, action_id = action_id, grant_epoch = current, attempt_state = state,
            delivery_state = latest[1] and delivery_status(latest[1]) or "empty", last_inbox_sequence = latest[1] and latest[1].inbox_sequence or 0,
            sendable = access.may_send(resource)}, false)
    end)
end
local function send(db: sql.DB, actor: string, request: unknown, is_reply: boolean): Result
    local mutation, invalid = authority.mutation(request)
    if not mutation then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local object = bounds.object(request) or {}
    local extra = bounds.fields(object, {"thread_id", "target_action_id", "sender_thread_id", "sender_action_id", "node_id", "grant_epoch",
        "idempotency_key", "message_id", "content", "payload_digest", "in_reply_to", "outcome"})
    if extra then return failure("INVALID_ARGUMENT", extra) end
    local target_action = bounds.id(object.target_action_id)
    local sender_thread = bounds.id(object.sender_thread_id)
    local sender_action = bounds.id(object.sender_action_id)
    local node_id = bounds.id(object.node_id)
    local grant_epoch = bounds.integer(object.grant_epoch)
    local message_id = bounds.id(object.message_id)
    if not target_action or not sender_thread or not sender_action or not node_id or not grant_epoch or grant_epoch < 1 or not message_id then
        return failure("INVALID_ARGUMENT", "destination, sender action, node, epoch and message_id are required")
    end
    local digest = bounds.id(object.payload_digest)
    local measured = sends.payload_digest({message_id = message_id, content = object.content})
    if not digest or #digest ~= 64 or digest ~= measured then return failure("INVALID_ARGUMENT", "payload_digest does not match message") end
    if is_reply ~= (object.in_reply_to ~= nil) or (is_reply and object.outcome == nil) or (not is_reply and object.outcome ~= nil) then
        return failure("INVALID_ARGUMENT", "reply correlation and outcome must accompany a reply only")
    end
    local submitted: Object = {message_id = message_id, message_kind = is_reply and "reply" or "request", sender_id = actor,
        sender_action_id = sender_action, recipient_ids = {}, recipient_action_ids = {target_action}, content = object.content}
    if is_reply then submitted.in_reply_to = object.in_reply_to; submitted.outcome = object.outcome end
    local decoded, decode_err = message.decode(submitted)
    if not decoded then return failure("INVALID_ARGUMENT", decode_err or "invalid message") end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local head, recipient, refused = target(tx, mutation.thread_id, target_action)
        if not head then return refused or failure("NOT_FOUND", "destination unavailable") end
        if head.state ~= "open" then return failure("INVALID_STATE", "destination thread is closed") end
        if node_id ~= node() then return failure("NOT_FOUND", "destination node is not local: " .. node_id .. "/" .. node()) end
        if not head.workspace_id or head.workspace_id ~= access.workspace() then return failure("DENIED", "sender and recipient workspaces differ") end
        if not access.may_send(address(head.workspace_id, node_id, target_action)) then return failure("DENIED", "no host send grant for address") end
        local blocked, block_err = delivery_block(tx, mutation.thread_id, target_action)
        if block_err then return block_err end
        local source, source_err = own_action(tx, actor, sender_thread, sender_action)
        if not source then return source_err or failure("DENIED", "sender action unavailable") end
        local replayed, replay_err = authority.replay(tx, actor, is_reply and "inbox_reply" or "inbox_send", mutation)
        if replay_err then return storage(replay_err) end
        if replayed then return replayed end
        local class = actor:match("^([^:]+)") or actor
        local accepted, acceptance_err = rows(tx, "SELECT sender_value FROM bee_thread_inbox_rules WHERE thread_id = ? AND action_id = ? AND " ..
            "((sender_kind = 'actor' AND sender_value = ?) OR (sender_kind = 'class' AND sender_value = ?)) LIMIT 1",
            {mutation.thread_id, target_action, actor, class})
        if not accepted then return acceptance_err or storage("read acceptance") end
        if #accepted == 0 then return failure("DENIED", "recipient owner has not accepted sender") end
        local current, current_err = epoch(tx, mutation.thread_id, target_action)
        if current_err then return current_err end
        if current ~= grant_epoch then return failure("CONFLICT", "grant epoch is stale") end
        local original: InboxRow? = nil
        if is_reply then
            local ref = decoded.in_reply_to
            if not ref then return failure("INVALID_ARGUMENT", "reply reference is required") end
            local origin, origin_err = rows(tx, "SELECT * FROM bee_thread_inbox_items WHERE thread_id = ? AND record_id = ?", {ref.thread_id, ref.record_id})
            if not origin then return origin_err or storage("read original inbox item") end
            original = origin[1]
            if not original or original.action_id ~= sender_action or original.sender_action_id ~= target_action or original.sender_actor ~= recipient
                or original.sender_thread_id ~= mutation.thread_id or original.sender_node_id ~= node_id then
                return failure("DENIED", "reply does not match an inbox request addressed to sender")
            end
            local source_record, source_record_err = reader.record(tx, ref.thread_id, ref.record_id)
            if source_record_err then return storage(source_record_err) end
            if not source_record then return failure("INTERNAL", "original inbox record is missing") end
            local source_message, source_decode_err = record.decode_json(source_record.record_json)
            if not source_message then return failure("INTERNAL", source_decode_err or "original inbox record is corrupt") end
            if source_message.kind ~= "message" or (source_message.body :: {message_kind: string}).message_kind ~= "request" then
                return failure("INVALID_ARGUMENT", "reply reference must name an inbox request")
            end
            if original.state == "replied" then return failure("CONFLICT", "inbox request already has a reply") end
        end
        local held, held_err = rows(tx, "SELECT next_sequence FROM bee_thread_inbox_epochs WHERE thread_id = ? AND action_id = ?", {mutation.thread_id, target_action})
        if not held then return held_err or storage("read inbox sequence") end
        local sequence = held[1] and math.floor(tonumber(held[1].next_sequence) or 0) or 0
        if sequence < 1 or sequence > MAX_ITEMS then return failure("LIMIT_EXCEEDED", "action inbox is full") end
        local record_body: Object = {message_id = decoded.message_id, message_kind = decoded.message_kind, sender_id = actor,
            sender_action_id = sender_action, recipient_ids = {recipient}, recipient_action_ids = {target_action}, content = decoded.content}
        if decoded.in_reply_to then record_body.in_reply_to = decoded.in_reply_to end
        if decoded.outcome then record_body.outcome = decoded.outcome end
        local recorded, recorded_err = message.decode(record_body)
        if not recorded then return failure("INTERNAL", recorded_err or "inbox record invalid") end
        local committed, commit_err = authority.commit_record(tx, head, "message", actor, "bee", recorded, {}, nil, nil, 0)
        if not committed then return commit_err or failure("INTERNAL", "commit failed") end
        local insert_err = execute(tx, "INSERT INTO bee_thread_inbox_items (thread_id, action_id, inbox_sequence, record_id, payload_digest, sender_actor, sender_action_id, sender_node_id, sender_thread_id, message_id, state, delivery_block, in_reply_to_thread_id, in_reply_to_record_id) " ..
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'committed', ?, ?, ?)",
            {mutation.thread_id, target_action, sequence, committed.record_id, digest, actor, sender_action, node_id, sender_thread, message_id,
                blocked or sql.NULL, decoded.in_reply_to and decoded.in_reply_to.thread_id or sql.NULL, decoded.in_reply_to and decoded.in_reply_to.record_id or sql.NULL})
        if insert_err then return insert_err end
        local advance_err = execute(tx, "UPDATE bee_thread_inbox_epochs SET next_sequence = ? WHERE thread_id = ? AND action_id = ?",
            {sequence + 1, mutation.thread_id, target_action})
        if advance_err then return advance_err end
        if original then
            local update_err = execute(tx, "UPDATE bee_thread_inbox_items SET state = 'replied', delivery_block = NULL, reply_thread_id = ?, reply_record_id = ? WHERE thread_id = ? AND record_id = ?",
                {mutation.thread_id, committed.record_id, original.thread_id, original.record_id})
            if update_err then return update_err end
        end
        return authority.remember(tx, actor, is_reply and "inbox_reply" or "inbox_send", mutation,
            {record_id = committed.record_id, thread_sequence = committed.sequence, inbox_sequence = sequence, payload_digest = digest, state = "committed",
                delivery_status = blocked or "committed"})
    end)
end
function M.send(db: sql.DB, actor: string, request: unknown): Result return send(db, actor, request, false) end
function M.reply(db: sql.DB, actor: string, request: unknown): Result return send(db, actor, request, true) end
function M.list(db: sql.DB, actor: string, request: unknown): Result
    local object = bounds.object(request)
    if not object then return failure("INVALID_ARGUMENT", "request must be an object") end
    local extra = bounds.fields(object, {"thread_id", "action_id", "after_sequence", "limit"})
    if extra then return failure("INVALID_ARGUMENT", extra) end
    local thread_id, action_id = bounds.id(object.thread_id), bounds.id(object.action_id)
    local after = bounds.integer(object.after_sequence)
    local limit = object.limit == nil and MAX_PAGE or bounds.integer(object.limit)
    if not thread_id or not action_id or not after or after < 0 or not limit or limit < 1 or limit > MAX_PAGE then
        return failure("INVALID_ARGUMENT", "thread, action and bounded inbox cursor are required")
    end
    local page_limit: integer = math.floor(tonumber(limit) or 0)
    return transaction.read(db, function(tx: sql.Transaction): Result
        local head, denied = own_action(tx, actor, thread_id, action_id)
        if not head then return denied or failure("DENIED", "not caller's action") end
        local found, read_err = rows(tx, "SELECT i.*, r.record_json FROM bee_thread_inbox_items i JOIN bee_thread_records r ON r.record_id = i.record_id " ..
            "WHERE i.thread_id = ? AND i.action_id = ? AND i.inbox_sequence > ? ORDER BY i.inbox_sequence LIMIT ?",
            {thread_id, action_id, after, page_limit + 1})
        if not found then return read_err or storage("read inbox") end
        local items: {Object} = {}
        for index = 1, math.min(#found, limit) do
            local item = found[index]
            local decoded, decode_err = record.decode_json(tostring(item.record_json))
            if not decoded then return failure("INTERNAL", decode_err or "stored inbox record is corrupt") end
            local body = decoded.body :: Object
            local view: Object = {thread_id = thread_id, inbox_sequence = item.inbox_sequence, record_id = item.record_id, thread_sequence = decoded.sequence,
                payload_digest = item.payload_digest, state = item.state, delivery_status = delivery_status(item), sender_action_id = item.sender_action_id,
                sender_node_id = item.sender_node_id, sender_thread_id = item.sender_thread_id, message_id = item.message_id,
                content = body.content, message_kind = body.message_kind}
            if body.in_reply_to then view.in_reply_to = body.in_reply_to end
            items[index] = view
        end
        return transaction.success({items = items, has_more = #found > limit, scanned_through = #items > 0 and items[#items].inbox_sequence or after}, false)
    end)
end
function M.ack(db: sql.DB, actor: string, request: unknown): Result
    local mutation, invalid = authority.mutation(request)
    if not mutation then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local object = bounds.object(request) or {}
    local extra = bounds.fields(object, {"thread_id", "action_id", "inbox_sequence", "idempotency_key"})
    if extra then return failure("INVALID_ARGUMENT", extra) end
    local action_id = bounds.id(object.action_id)
    local sequence = bounds.integer(object.inbox_sequence)
    if not action_id or not sequence or sequence < 1 then return failure("INVALID_ARGUMENT", "action and inbox sequence are required") end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local head, denied = own_action(tx, actor, mutation.thread_id, action_id)
        if not head then return denied or failure("DENIED", "not caller's action") end
        local replayed, replay_err = authority.replay(tx, actor, "inbox_ack", mutation)
        if replay_err then return storage(replay_err) end
        if replayed then return replayed end
        local found, read_err = rows(tx, "SELECT record_id, state FROM bee_thread_inbox_items WHERE thread_id = ? AND action_id = ? AND inbox_sequence = ?",
            {mutation.thread_id, action_id, sequence})
        if not found then return read_err or storage("read inbox item") end
        local item = found[1]
        if not item then return failure("NOT_FOUND", "inbox item does not exist") end
        local state = tostring(item.state)
        if state ~= "acknowledged" and state ~= "replied" then
            local update_err = execute(tx, "UPDATE bee_thread_inbox_items SET state = 'acknowledged', delivery_block = NULL WHERE thread_id = ? AND action_id = ? AND inbox_sequence = ?",
                {mutation.thread_id, action_id, sequence})
            if update_err then return update_err end
            state = "acknowledged"
        end
        return authority.remember(tx, actor, "inbox_ack", mutation, {inbox_sequence = sequence, record_id = item.record_id, state = state})
    end)
end
-- Check the carrier fence in the same transaction that changes the offer.
-- A caller's action identity alone does not authorize transport dispatch.
local function carrier_target(tx: sql.Transaction, actor: string, thread_id: string, action_id: string, attempt_id: string, carrier_epoch: integer): Result?
    local head, refused = own_action(tx, actor, thread_id, action_id)
    if not head then return refused or failure("DENIED", "not caller's action") end
    if not access.may_carry(thread_id) then return failure("DENIED", "caller holds no carrier authority") end
    if head.state ~= "open" then return failure("INVALID_STATE", "thread is closed") end
    local attempt, attempt_err = reader.attempt(tx, thread_id, attempt_id)
    if attempt_err then return storage(attempt_err) end
    if not attempt or attempt.action_id ~= action_id then return failure("DENIED", "attempt is not on target action") end
    if attempt.state == "ended" then return failure("INVALID_STATE", "attempt has ended") end
    local carriers, read_err = rows(tx, "SELECT carrier_epoch FROM bee_thread_carriers WHERE thread_id = ? AND attempt_id = ?", {thread_id, attempt_id})
    if not carriers then return read_err or storage("read carrier epoch") end
    if not carriers[1] or tonumber(carriers[1].carrier_epoch) ~= carrier_epoch then return failure("CONFLICT", "carrier epoch is not current") end
    return nil
end
local function carrier_request(request: unknown, allowed: {string}): (string?, string?, string?, integer?, Result?)
    local object = bounds.object(request)
    if not object then return nil, nil, nil, nil, failure("INVALID_ARGUMENT", "request must be an object") end
    local extra = bounds.fields(object, allowed)
    if extra then return nil, nil, nil, nil, failure("INVALID_ARGUMENT", extra) end
    local thread_id, action_id, attempt_id = bounds.id(object.thread_id), bounds.id(object.action_id), bounds.id(object.attempt_id)
    local carrier_epoch = bounds.integer(object.carrier_epoch)
    if not thread_id or not action_id or not attempt_id or not carrier_epoch or carrier_epoch < 1 then
        return nil, nil, nil, nil, failure("INVALID_ARGUMENT", "thread, action, attempt and positive carrier epoch are required")
    end
    return thread_id, action_id, attempt_id, carrier_epoch, nil
end
-- The oldest outstanding item blocks later items. A carrier replacement may
-- reoffer it with the same record id even when its earlier transport result
-- was accepted: transport acceptance never certifies agent comprehension.
function M.offer(db: sql.DB, actor: string, request: unknown): Result
    local thread_id, action_id, attempt_id, carrier_epoch, invalid = carrier_request(request,
        {"thread_id", "action_id", "attempt_id", "carrier_epoch"})
    if not thread_id or not action_id or not attempt_id or not carrier_epoch then return invalid or failure("INVALID_ARGUMENT", "invalid carrier request") end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local refused = carrier_target(tx, actor, thread_id, action_id, attempt_id, carrier_epoch)
        if refused then return refused end
        local found, read_err = rows(tx, "SELECT i.*, r.record_json FROM bee_thread_inbox_items i JOIN bee_thread_records r ON r.record_id = i.record_id " ..
            "WHERE i.thread_id = ? AND i.action_id = ? AND i.state NOT IN ('acknowledged','replied') ORDER BY i.inbox_sequence LIMIT 1", {thread_id, action_id})
        if not found then return read_err or storage("read next inbox item") end
        local item = found[1]
        if not item then return transaction.success({empty = true}, false) end
        local same_carrier = item.offer_attempt_id == attempt_id and tonumber(item.offer_carrier_epoch) == carrier_epoch
        local dispatch = not same_carrier or item.state == "committed"
        if dispatch then
            local changed = execute(tx, "UPDATE bee_thread_inbox_items SET state = 'offered', delivery_block = NULL, offer_attempt_id = ?, offer_carrier_epoch = ?, " ..
                "offer_count = offer_count + 1, offered_at = ?, transport_accepted_at = NULL WHERE thread_id = ? AND action_id = ? AND inbox_sequence = ?",
                {attempt_id, carrier_epoch, transaction.now(), thread_id, action_id, item.inbox_sequence})
            if changed then return changed end
        end
        local decoded, decode_err = record.decode_json(tostring(item.record_json))
        if not decoded then return failure("INTERNAL", decode_err or "stored inbox record is corrupt") end
        local body = decoded.body :: Object
        local view: Object = {thread_id = thread_id, action_id = action_id, inbox_sequence = item.inbox_sequence, record_id = item.record_id,
            payload_digest = item.payload_digest, message_id = item.message_id, message_kind = body.message_kind, content = body.content,
            sender_action_id = item.sender_action_id, sender_thread_id = item.sender_thread_id, sender_node_id = item.sender_node_id,
            state = dispatch and "offered" or item.state, dispatch = dispatch, offer_count = (tonumber(item.offer_count) or 0) + (dispatch and 1 or 0)}
        if body.in_reply_to then view.in_reply_to = body.in_reply_to end
        return transaction.success(view, false)
    end)
end
function M.transport(db: sql.DB, actor: string, request: unknown): Result
    local thread_id, action_id, attempt_id, carrier_epoch, invalid = carrier_request(request,
        {"thread_id", "action_id", "attempt_id", "carrier_epoch", "inbox_sequence", "record_id"})
    if not thread_id or not action_id or not attempt_id or not carrier_epoch then return invalid or failure("INVALID_ARGUMENT", "invalid carrier request") end
    local object = bounds.object(request) or {}
    local sequence, record_id = bounds.integer(object.inbox_sequence), bounds.id(object.record_id)
    if not sequence or sequence < 1 or not record_id then return failure("INVALID_ARGUMENT", "sequence and record id are required") end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local refused = carrier_target(tx, actor, thread_id, action_id, attempt_id, carrier_epoch)
        if refused then return refused end
        local found, read_err = rows(tx, "SELECT record_id, state, offer_attempt_id, offer_carrier_epoch FROM bee_thread_inbox_items " ..
            "WHERE thread_id = ? AND action_id = ? AND inbox_sequence = ?", {thread_id, action_id, sequence})
        if not found then return read_err or storage("read offered item") end
        local item = found[1]
        if not item then return failure("NOT_FOUND", "inbox item does not exist") end
        if item.record_id ~= record_id or item.offer_attempt_id ~= attempt_id or tonumber(item.offer_carrier_epoch) ~= carrier_epoch then
            return failure("CONFLICT", "offer is not held by this carrier")
        end
        if item.state == "offered" then
            local changed = execute(tx, "UPDATE bee_thread_inbox_items SET state = 'transport_accepted', transport_accepted_at = ? " ..
                "WHERE thread_id = ? AND action_id = ? AND inbox_sequence = ?", {transaction.now(), thread_id, action_id, sequence})
            if changed then return changed end
            return transaction.success({record_id = record_id, inbox_sequence = sequence, state = "transport_accepted"}, false)
        end
        if item.state == "transport_accepted" or item.state == "acknowledged" or item.state == "replied" then
            return transaction.success({record_id = record_id, inbox_sequence = sequence, state = item.state}, false)
        end
        return failure("CONFLICT", "item was not offered")
    end)
end
return M
