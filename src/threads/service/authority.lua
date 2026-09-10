-- MIT. Thread authority operations: membership, submissions and ordered
-- reads. Each mutation validates its request, checks the caller inside the
-- transaction, and commits its rows with its idempotent reply.
local sql = require("sql")
local json = require("json")
local bounds = require("bounds")
local canonical = require("canonical")
local values = require("values")
local record = require("record")
local message = require("message")
local observation = require("observation")
local record_types = require("record_types")
local types = require("types")
local access = require("access")
local reader = require("reader")
local transaction = require("transaction")
local M = {}
type Result = transaction.Result
type Mutation = {thread_id: string, idempotency_key: string, request_json: string}
type Context = {causation: record_types.Ref?, correlation_id: string?, action_id: string?, attempt_id: string?, turn_id: string?}
local function failure(code: string, message: string): Result
    return transaction.failure(code, message)
end
local function storage(err: string): Result
    if err == "BUSY" then return transaction.storage_failure("thread database is busy") end
    return transaction.failure("INTERNAL", err)
end
function M.summary(head: reader.Head): types.Summary
    return {thread_id = head.thread_id, title = head.title, state = head.state, revision = head.revision,
        head_sequence = head.head_sequence, owner_id = head.owner_actor, created_at = head.created_at}
end
-- Every mutation names its thread and an idempotency key; the canonical
-- request is what a retry must repeat exactly.
function M.mutation(request: unknown): (Mutation?, Result?)
    local object = bounds.object(request)
    if not object then return nil, failure("INVALID_ARGUMENT", "request must be an object") end
    local thread_id, key = bounds.id(object.thread_id), bounds.id(object.idempotency_key)
    if not thread_id then return nil, failure("INVALID_ARGUMENT", "thread_id is not an identifier") end
    if not key then return nil, failure("INVALID_ARGUMENT", "idempotency_key is not an identifier") end
    local encoded, encode_error = canonical.encode(object)
    if not encoded then return nil, failure("INVALID_ARGUMENT", "request is not encodable: " .. tostring(encode_error)) end
    return {thread_id = thread_id, idempotency_key = key, request_json = encoded}, nil
end
-- A stored command with the same key replays its reply when the request is
-- identical and conflicts otherwise. Returns nil when there is none.
function M.replay(tx: sql.Transaction, actor: string, operation: string, mutation: Mutation): (Result?, string?)
    local command, err = reader.command(tx, mutation.thread_id, actor, mutation.idempotency_key)
    if err then return nil, err end
    if not command then return nil, nil end
    if command.operation ~= operation or command.request_json ~= mutation.request_json then
        return failure("CONFLICT", "idempotency_key was used by a different request"), nil
    end
    local value: unknown, decode_error = json.decode(command.reply_json)
    if decode_error then return nil, "thread command reply is corrupt" end
    return transaction.success(value, true), nil
end
function M.remember(tx: sql.Transaction, actor: string, operation: string, mutation: Mutation, value: unknown): Result
    local reply_json, encode_error = canonical.encode(value)
    if not reply_json then return failure("INTERNAL", "reply is not encodable: " .. tostring(encode_error)) end
    local err = transaction.insert_command(tx, mutation.thread_id, actor, mutation.idempotency_key, operation, mutation.request_json, reply_json)
    if err then return storage(err) end
    return transaction.success(value, false)
end
-- Loads the head and the caller's active membership, or explains why not.
function M.membership(tx: sql.Transaction, thread_id: string, actor: string): (reader.Head?, reader.Member?, Result?)
    local head, head_err = reader.head(tx, thread_id)
    if head_err then return nil, nil, storage(head_err) end
    if not head then return nil, nil, failure("NOT_FOUND", "thread does not exist") end
    local member, member_err = reader.member(tx, thread_id, actor)
    if member_err then return nil, nil, storage(member_err) end
    if not member or not member.active then return head, nil, failure("DENIED", "caller is not a member of the thread") end
    return head, member, nil
end
local function optional_integer(object: {[string]: unknown}, name: string): (integer?, boolean)
    local raw: unknown = object[name]
    if raw == nil then return nil, true end
    local number = bounds.integer(raw)
    if not number then return nil, false end
    return number, true
end
function M.create(db: sql.DB, actor: string, request: unknown): Result
    local mutation, invalid = M.mutation(request)
    if not mutation then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local object = bounds.object(request) or {}
    local unknown_field = bounds.fields(object, {"thread_id", "idempotency_key", "title"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local title = bounds.text(object.title, bounds.MAX_TITLE_BYTES)
    if not title or #title == 0 or title:find("%c") then return failure("INVALID_ARGUMENT", "title must be one line of bounded text") end
    local title_text = tostring(title)
    if not access.may_create(mutation.thread_id) then return failure("DENIED", "caller may not create threads") end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local head, head_err = reader.head(tx, mutation.thread_id)
        if head_err then return storage(head_err) end
        if head then
            local replayed, replay_err = M.replay(tx, actor, "create", mutation)
            if replay_err then return storage(replay_err) end
            if replayed then return replayed end
            return failure("CONFLICT", "thread already exists")
        end
        local now = transaction.now()
        local insert_err = transaction.insert_head(tx, {thread_id = mutation.thread_id, owner_actor = actor, title = title_text, created_at = now})
        if insert_err then return storage(insert_err) end
        local member_err = transaction.insert_member(tx, mutation.thread_id, actor, "owner", 1)
        if member_err then return storage(member_err) end
        local created, created_err = reader.head(tx, mutation.thread_id)
        if not created then return storage(created_err or "read created thread") end
        return M.remember(tx, actor, "create", mutation, M.summary(created))
    end)
end
function M.get(db: sql.DB, actor: string, request: unknown): Result
    local object = bounds.object(request)
    if not object then return failure("INVALID_ARGUMENT", "request must be an object") end
    local unknown_field = bounds.fields(object, {"thread_id"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local thread_id = bounds.id(object.thread_id)
    if not thread_id then return failure("INVALID_ARGUMENT", "thread_id is not an identifier") end
    return transaction.read(db, function(tx: sql.Transaction): Result
        local head, member, denied = M.membership(tx, thread_id, actor)
        if not head or not member then return denied or failure("DENIED", "caller is not a member of the thread") end
        local membership: types.Membership = {member_id = member.actor, role = member.role, revision = member.revision, active = member.active}
        return transaction.success({summary = M.summary(head), membership = membership}, false)
    end)
end
function M.list(db: sql.DB, actor: string, request: unknown): Result
    local object = bounds.object(request)
    if not object then return failure("INVALID_ARGUMENT", "request must be an object") end
    local unknown_field = bounds.fields(object, {"after_thread_id", "limit"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local after = ""
    if object.after_thread_id ~= nil then
        local id = bounds.id(object.after_thread_id)
        if not id then return failure("INVALID_ARGUMENT", "after_thread_id is not an identifier") end
        after = id
    end
    local limit = bounds.MAX_PAGE_RECORDS
    if object.limit ~= nil then
        local number = bounds.integer(object.limit)
        if not number or number < 1 or number > bounds.MAX_PAGE_RECORDS then return failure("INVALID_ARGUMENT", "limit must be between 1 and " .. tostring(bounds.MAX_PAGE_RECORDS)) end
        limit = number
    end
    return transaction.read(db, function(tx: sql.Transaction): Result
        local heads, err = reader.accessible_heads(tx, actor, after, limit)
        if not heads then return storage(err or "read accessible threads") end
        local summaries: {types.Summary} = {}
        for index = 1, math.min(#heads, limit) do summaries[index] = M.summary(heads[index]) end
        local value: {[string]: unknown} = {threads = summaries}
        if #heads > limit then value.next_after_thread_id = summaries[#summaries].thread_id end
        return transaction.success(value, false)
    end)
end
function M.join(db: sql.DB, actor: string, request: unknown): Result
    local mutation, invalid = M.mutation(request)
    if not mutation then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local object = bounds.object(request) or {}
    local unknown_field = bounds.fields(object, {"thread_id", "idempotency_key", "member_id", "role", "expected_revision"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local member_id = bounds.id(object.member_id)
    local role = bounds.member(object.role, {"participant", "observer"})
    local expected = bounds.integer(object.expected_revision)
    if not member_id then return failure("INVALID_ARGUMENT", "member_id is not an identifier") end
    if not role then return failure("INVALID_ARGUMENT", "role must be participant or observer") end
    if not expected or expected < 1 then return failure("INVALID_ARGUMENT", "expected_revision must be a positive integer") end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local head, caller, denied = M.membership(tx, mutation.thread_id, actor)
        if not head or not caller then return denied or failure("DENIED", "caller is not a member of the thread") end
        local replayed, replay_err = M.replay(tx, actor, "join", mutation)
        if replay_err then return storage(replay_err) end
        if replayed then return replayed end
        if not access.administers(caller.role) then return failure("DENIED", "only the owner administers membership") end
        if head.state ~= "open" then return failure("INVALID_STATE", "thread is closed") end
        if head.revision ~= expected then return failure("CONFLICT", "expected_revision does not match the thread") end
        local existing, existing_err = reader.member(tx, mutation.thread_id, member_id)
        if existing_err then return storage(existing_err) end
        if existing and existing.active then return failure("CONFLICT", "member is already active") end
        local active, count_err = reader.count(tx, "SELECT COUNT(*) AS count FROM bee_thread_members WHERE thread_id = ? AND active = 1", {mutation.thread_id}, "active members")
        if not active then return storage(count_err or "count active members") end
        if active >= bounds.MAX_THREAD_MEMBERS then return failure("LIMIT_EXCEEDED", "thread membership is full") end
        local revision = head.revision + 1
        local write_err: string?
        if existing then
            write_err = transaction.set_member(tx, mutation.thread_id, member_id, role, revision, true)
        else
            write_err = transaction.insert_member(tx, mutation.thread_id, member_id, role, revision)
        end
        if write_err then return storage(write_err) end
        local head_err = transaction.set_revision(tx, mutation.thread_id, revision, head.state)
        if head_err then return storage(head_err) end
        local membership: types.Membership = {member_id = member_id, role = role, revision = revision, active = true}
        return M.remember(tx, actor, "join", mutation, membership)
    end)
end
function M.leave(db: sql.DB, actor: string, request: unknown): Result
    local mutation, invalid = M.mutation(request)
    if not mutation then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local object = bounds.object(request) or {}
    local unknown_field = bounds.fields(object, {"thread_id", "idempotency_key", "member_id", "expected_revision"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local member_id = bounds.id(object.member_id)
    local expected = bounds.integer(object.expected_revision)
    if not member_id then return failure("INVALID_ARGUMENT", "member_id is not an identifier") end
    if not expected or expected < 1 then return failure("INVALID_ARGUMENT", "expected_revision must be a positive integer") end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local head, caller, denied = M.membership(tx, mutation.thread_id, actor)
        if not head or not caller then return denied or failure("DENIED", "caller is not a member of the thread") end
        local replayed, replay_err = M.replay(tx, actor, "leave", mutation)
        if replay_err then return storage(replay_err) end
        if replayed then return replayed end
        if member_id ~= actor and not access.administers(caller.role) then return failure("DENIED", "only the owner removes other members") end
        local target = caller
        if member_id ~= actor then
            local other, other_err = reader.member(tx, mutation.thread_id, member_id)
            if other_err then return storage(other_err) end
            if not other or not other.active then return failure("INVALID_STATE", "member is not active") end
            target = other
        end
        if target.role == "owner" then return failure("INVALID_STATE", "the owner cannot leave") end
        if head.revision ~= expected then return failure("CONFLICT", "expected_revision does not match the thread") end
        local revision = head.revision + 1
        local write_err = transaction.set_member(tx, mutation.thread_id, member_id, target.role, revision, false)
        if write_err then return storage(write_err) end
        local head_err = transaction.set_revision(tx, mutation.thread_id, revision, head.state)
        if head_err then return storage(head_err) end
        local membership: types.Membership = {member_id = member_id, role = target.role, revision = revision, active = false}
        return M.remember(tx, actor, "leave", mutation, membership)
    end)
end
function M.close(db: sql.DB, actor: string, request: unknown): Result
    local mutation, invalid = M.mutation(request)
    if not mutation then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local object = bounds.object(request) or {}
    local unknown_field = bounds.fields(object, {"thread_id", "idempotency_key", "expected_revision"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local expected = bounds.integer(object.expected_revision)
    if not expected or expected < 1 then return failure("INVALID_ARGUMENT", "expected_revision must be a positive integer") end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local head, caller, denied = M.membership(tx, mutation.thread_id, actor)
        if not head or not caller then return denied or failure("DENIED", "caller is not a member of the thread") end
        local replayed, replay_err = M.replay(tx, actor, "close", mutation)
        if replay_err then return storage(replay_err) end
        if replayed then return replayed end
        if not access.administers(caller.role) then return failure("DENIED", "only the owner closes the thread") end
        if head.state ~= "open" then return failure("INVALID_STATE", "thread is closed") end
        if head.revision ~= expected then return failure("CONFLICT", "expected_revision does not match the thread") end
        local open, count_err = reader.count(tx, "SELECT COUNT(*) AS count FROM bee_thread_actions WHERE thread_id = ? AND state <> 'ended'", {mutation.thread_id}, "open actions")
        if not open then return storage(count_err or "count open actions") end
        if open > 0 then return failure("INVALID_STATE", "thread has unsettled actions") end
        local revision = head.revision + 1
        local head_err = transaction.set_revision(tx, mutation.thread_id, revision, "closed")
        if head_err then return storage(head_err) end
        local closed, closed_err = reader.head(tx, mutation.thread_id)
        if not closed then return storage(closed_err or "read closed thread") end
        return M.remember(tx, actor, "close", mutation, M.summary(closed))
    end)
end
-- Optional references a submission may carry; each must name something
-- committed in this thread.
function M.context(tx: sql.Transaction, thread_id: string, value: unknown): (Context?, Result?)
    local context: Context = {}
    if value == nil then return context, nil end
    local object = bounds.object(value)
    if not object then return nil, failure("INVALID_ARGUMENT", "context must be an object") end
    local unknown_field = bounds.fields(object, {"causation", "correlation_id", "action_id", "attempt_id", "turn_id"})
    if unknown_field then return nil, failure("INVALID_ARGUMENT", unknown_field) end
    for _, name in ipairs({"correlation_id", "action_id", "attempt_id", "turn_id"}) do
        local id, valid = values.optional_id(object, name)
        if not valid then return nil, failure("INVALID_ARGUMENT", name .. " is not an identifier") end
        if name == "correlation_id" then context.correlation_id = id
        elseif name == "action_id" then context.action_id = id
        elseif name == "attempt_id" then context.attempt_id = id
        else context.turn_id = id end
    end
    if object.causation ~= nil then
        local ref, ref_error = values.ref(object.causation)
        if not ref then return nil, failure("INVALID_ARGUMENT", "causation: " .. tostring(ref_error)) end
        if ref.thread_id ~= thread_id then return nil, failure("INVALID_ARGUMENT", "causation must reference this thread") end
        local cause, cause_err = reader.record(tx, thread_id, ref.record_id)
        if cause_err then return nil, storage(cause_err) end
        if not cause then return nil, failure("INVALID_ARGUMENT", "causation record does not exist") end
        context.causation = ref
    end
    if context.attempt_id and not context.action_id then return nil, failure("INVALID_ARGUMENT", "attempt_id needs action_id") end
    if context.turn_id and not context.attempt_id then return nil, failure("INVALID_ARGUMENT", "turn_id needs attempt_id") end
    if context.action_id then
        local action, action_err = reader.action(tx, thread_id, context.action_id)
        if action_err then return nil, storage(action_err) end
        if not action then return nil, failure("INVALID_ARGUMENT", "action does not exist") end
    end
    if context.attempt_id then
        local attempt, attempt_err = reader.attempt(tx, thread_id, context.attempt_id)
        if attempt_err then return nil, storage(attempt_err) end
        if not attempt or attempt.action_id ~= context.action_id then return nil, failure("INVALID_ARGUMENT", "attempt does not belong to the action") end
    end
    if context.turn_id then
        local turn, turn_err = reader.turn(tx, thread_id, context.turn_id)
        if turn_err then return nil, storage(turn_err) end
        if not turn or turn.attempt_id ~= context.attempt_id then return nil, failure("INVALID_ARGUMENT", "turn does not belong to the attempt") end
    end
    return context, nil
end
-- Commits one record after the head, reserving capacity for the terminal
-- records still owed plus any new obligation this record creates.
function M.commit_record(tx: sql.Transaction, head: reader.Head, kind: record_types.Kind, producer_id: string, source: record_types.Source,
    body: record_types.Body, context: Context, event_scope: string?, event_key: string?, new_obligations: integer): (types.Committed?, Result?)
    local obligations, obligations_err = reader.obligations(tx, head.thread_id)
    if not obligations then return nil, storage(obligations_err or "count obligations") end
    local reserved = obligations.open_actions + obligations.running_attempts + obligations.open_turns + obligations.open_requests + obligations.live_claims
    if head.head_sequence + 1 + reserved + new_obligations > bounds.MAX_THREAD_RECORDS then
        return nil, failure("LIMIT_EXCEEDED", "thread has no capacity for this record and the receipts still owed")
    end
    local record_id, id_err = transaction.record_id()
    if not record_id then return nil, failure("INTERNAL", id_err or "allocate record identifier") end
    local sequence = head.head_sequence + 1
    local now = transaction.now()
    local envelope: record_types.Record = {schema_revision = bounds.SCHEMA_REVISION, record_id = record_id, thread_id = head.thread_id,
        sequence = sequence, recorded_at = now, kind = kind, producer_id = producer_id, source = source, causation = context.causation,
        correlation_id = context.correlation_id, action_id = context.action_id, attempt_id = context.attempt_id, turn_id = context.turn_id, body = body}
    local encoded, encode_error = record.encode(envelope)
    if not encoded then return nil, failure("INVALID_ARGUMENT", encode_error or "record is not encodable") end
    local insert_err = transaction.insert_record(tx, {record_id = record_id, thread_id = head.thread_id, sequence = sequence, kind = kind,
        producer_id = producer_id, source = source, event_scope = event_scope, event_key = event_key, action_id = context.action_id,
        attempt_id = context.attempt_id, turn_id = context.turn_id, record_json = encoded, committed_at = now})
    if insert_err then return nil, storage(insert_err) end
    head.head_sequence = sequence
    return {record_id = record_id, sequence = sequence}, nil
end
-- A reply settles the sender's own obligation for the request it names.
-- Returns the request obligation, or the failure that stops the commit.
local function correlated_request(tx: sql.Transaction, head: reader.Head, caller: reader.Member, decoded: record_types.Message): (reader.Obligation?, Result?)
    local ref = decoded.in_reply_to
    if not ref then return nil, failure("INVALID_ARGUMENT", "reply needs in_reply_to") end
    if ref.thread_id ~= head.thread_id then return nil, failure("UNSUPPORTED_CAPABILITY", "cross-thread replies are not supported") end
    local stored, stored_err = reader.record(tx, head.thread_id, ref.record_id)
    if stored_err then return nil, storage(stored_err) end
    if not stored then return nil, failure("NOT_FOUND", "the request record does not exist") end
    if stored.kind ~= "message" then return nil, failure("INVALID_ARGUMENT", "in_reply_to must name a request message") end
    local request, request_error = record.decode_json(stored.record_json)
    if not request then return nil, failure("INTERNAL", request_error or "stored record is corrupt") end
    local body = request.body :: record_types.Message
    if body.message_kind ~= "request" then return nil, failure("INVALID_ARGUMENT", "in_reply_to must name a request message") end
    local obligation, obligation_err = reader.obligation(tx, head.thread_id, body.message_id, caller.actor)
    if obligation_err then return nil, storage(obligation_err) end
    if not obligation then return nil, failure("INVALID_STATE", "the sender holds no obligation for that request") end
    if obligation.state == "answered" then return nil, failure("CONFLICT", "the request is already answered by this recipient") end
    if obligation.state == "abandoned" then return nil, failure("INVALID_STATE", "the obligation was abandoned; reconcile it first") end
    return obligation, nil
end
function M.submit_message(tx: sql.Transaction, head: reader.Head, caller: reader.Member, body: unknown, context: Context): Result
    if not access.submits(caller.role) then return failure("DENIED", "observers do not submit messages") end
    local object = bounds.object(body)
    if not object then return failure("INVALID_ARGUMENT", "message must be an object") end
    local submission: {[string]: unknown} = {}
    for key, item in pairs(object) do submission[key] = item end
    if submission.sender_id ~= nil and submission.sender_id ~= caller.actor then return failure("DENIED", "sender_id must be the caller") end
    submission.sender_id = caller.actor
    local decoded, decode_error = message.decode(submission)
    if not decoded then return failure("INVALID_ARGUMENT", "message: " .. tostring(decode_error)) end
    local settled: reader.Obligation? = nil
    if decoded.message_kind == "reply" then
        local obligation, refused = correlated_request(tx, head, caller, decoded)
        if not obligation then return refused or failure("INTERNAL", "request unavailable") end
        settled = obligation
    end
    if #decoded.recipient_ids > 0 then
        local total, count_err = reader.count(tx, "SELECT COUNT(*) AS count FROM bee_thread_obligations WHERE thread_id = ?", {head.thread_id}, "obligations")
        if not total then return storage(count_err or "count obligations") end
        if total + #decoded.recipient_ids > bounds.MAX_THREAD_OBLIGATIONS then return failure("LIMIT_EXCEEDED", "thread obligation limit reached") end
    end
    -- A request owes one answer or abandonment per recipient.
    local owed = 0
    if decoded.message_kind == "request" then owed = #decoded.recipient_ids end
    local committed, refused = M.commit_record(tx, head, "message", caller.actor, "bee", decoded, context, nil, nil, owed)
    if not committed then return refused or failure("INTERNAL", "commit failed") end
    for _, recipient in ipairs(decoded.recipient_ids) do
        local insert_err = transaction.insert_obligation(tx, head.thread_id, decoded.message_id, recipient, committed.record_id, decoded.message_kind, committed.sequence)
        if insert_err then return storage(insert_err) end
    end
    if settled then
        local answered: record_types.Answered = {request_message_id = settled.message_id, recipient_id = caller.actor,
            reply_message_id = decoded.message_id, outcome = decoded.outcome or "succeeded"}
        local answer_context: Context = {causation = {thread_id = head.thread_id, record_id = committed.record_id}, correlation_id = context.correlation_id}
        local mark, mark_refused = M.commit_record(tx, head, "request.answered", caller.actor, "bee", answered, answer_context, nil, nil, -1)
        if not mark then return mark_refused or failure("INTERNAL", "commit failed") end
        local answer_err = transaction.answer_obligation(tx, head.thread_id, settled.message_id, caller.actor, committed.record_id, mark.record_id)
        if answer_err then return storage(answer_err) end
        -- A reply proves the request arrived; only an exact live claim by the
        -- same actor is acknowledged with it.
        if settled.delivery_id then
            local delivery, delivery_err = reader.delivery(tx, head.thread_id, settled.delivery_id)
            if delivery_err then return storage(delivery_err) end
            if delivery and delivery.state == "claimed" and delivery.claimant_actor == caller.actor then
                local delivered: record_types.DeliveryMark = {delivery_id = delivery.delivery_id, message_id = delivery.message_id, recipient_id = delivery.recipient_id,
                    state = "delivered", owner_epoch = delivery.owner_incarnation, channel = delivery.channel, evidence_ref = committed.record_id}
                local ack, ack_refused = M.commit_record(tx, head, "delivery.mark", caller.actor, "bee", delivered, answer_context, nil, nil, -1)
                if not ack then return ack_refused or failure("INTERNAL", "commit failed") end
                local set_err = transaction.set_delivery(tx, head.thread_id, delivery.delivery_id, "delivered", ack.record_id, committed.record_id)
                if set_err then return storage(set_err) end
            end
        end
    end
    return transaction.success(committed, false)
end
-- Commits one decoded observation for a producer, or replays the record
-- already committed under the same scope and event_key. A different body
-- under a used key is a conflict.
function M.commit_observation(tx: sql.Transaction, head: reader.Head, producer_id: string, source: record_types.Source, decoded: record_types.Observation, context: Context): Result
    local scope = source .. "/" .. (context.attempt_id or "")
    local existing, existing_err = reader.producer_event(tx, head.thread_id, producer_id, scope, decoded.event_key)
    if existing_err then return storage(existing_err) end
    if existing then
        local stored, stored_error = record.decode_json(existing.record_json)
        if not stored then return failure("INTERNAL", stored_error or "stored record is corrupt") end
        if record.encode_body("observation", stored.body) ~= record.encode_body("observation", decoded) then
            return failure("CONFLICT", "event_key was used by a different observation")
        end
        return transaction.success({record_id = existing.record_id, sequence = existing.sequence}, true)
    end
    local committed, refused = M.commit_record(tx, head, "observation", producer_id, source, decoded, context, scope, decoded.event_key, 0)
    if not committed then return refused or failure("INTERNAL", "commit failed") end
    return transaction.success(committed, false)
end
-- Commits one record of any family under a producer scope and key, or
-- replays the record already committed under them; different content under
-- a used key is a conflict.
function M.commit_keyed(tx: sql.Transaction, head: reader.Head, kind: record_types.Kind, producer_id: string, source: record_types.Source, body: record_types.Body, context: Context, scope: string, key: string): Result
    local existing, existing_err = reader.producer_event(tx, head.thread_id, producer_id, scope, key)
    if existing_err then return storage(existing_err) end
    if existing then
        local stored, stored_error = record.decode_json(existing.record_json)
        if not stored then return failure("INTERNAL", stored_error or "stored record is corrupt") end
        if stored.kind ~= kind or record.encode_body(kind, stored.body) ~= record.encode_body(kind, body) then
            return failure("CONFLICT", "event key was used by a different record")
        end
        return transaction.success({record_id = existing.record_id, sequence = existing.sequence}, true)
    end
    local committed, refused = M.commit_record(tx, head, kind, producer_id, source, body, context, scope, key, 0)
    if not committed then return refused or failure("INTERNAL", "commit failed") end
    return transaction.success(committed, false)
end
local function submit_observation(tx: sql.Transaction, head: reader.Head, caller: reader.Member, source: record_types.Source, body: unknown, context: Context): Result
    if not access.submits(caller.role) then return failure("DENIED", "observers do not submit observations") end
    if not access.may_observe(head.thread_id) then return failure("DENIED", "caller is not an authorized producer") end
    local decoded, decode_error = observation.decode(body)
    if not decoded then return failure("INVALID_ARGUMENT", "observation: " .. tostring(decode_error)) end
    return M.commit_observation(tx, head, caller.actor, source, decoded, context)
end
function M.record(db: sql.DB, actor: string, request: unknown): Result
    local mutation, invalid = M.mutation(request)
    if not mutation then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local object = bounds.object(request) or {}
    local unknown_field = bounds.fields(object, {"thread_id", "idempotency_key", "kind", "source", "body", "context"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local kind = bounds.member(object.kind, {"observation", "message"})
    if not kind then return failure("INVALID_ARGUMENT", "kind must be observation or message") end
    local source: record_types.Source = "bee"
    if kind == "observation" then
        local declared = bounds.member(object.source, {"stream", "hook", "transcript", "mcp"})
        if not declared then return failure("INVALID_ARGUMENT", "observation source must be stream, hook, transcript or mcp") end
        source = declared :: record_types.Source
    elseif object.source ~= nil then
        return failure("INVALID_ARGUMENT", "messages carry no source")
    end
    if object.body == nil then return failure("INVALID_ARGUMENT", "body is required") end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local head, caller, denied = M.membership(tx, mutation.thread_id, actor)
        if not head or not caller then return denied or failure("DENIED", "caller is not a member of the thread") end
        local replayed, replay_err = M.replay(tx, actor, "record", mutation)
        if replay_err then return storage(replay_err) end
        if replayed then return replayed end
        if head.state ~= "open" then return failure("INVALID_STATE", "thread is closed") end
        local context, context_error = M.context(tx, mutation.thread_id, object.context)
        if not context then return context_error or failure("INVALID_ARGUMENT", "invalid context") end
        local result: Result
        if kind == "message" then
            result = M.submit_message(tx, head, caller, object.body, context)
        else
            result = submit_observation(tx, head, caller, source, object.body, context)
        end
        if not result.ok then return result end
        if result.replayed then return result end
        return M.remember(tx, actor, "record", mutation, result.value)
    end)
end
local SCAN_WINDOW = 1024
function M.read_after(db: sql.DB, actor: string, request: unknown): Result
    local object = bounds.object(request)
    if not object then return failure("INVALID_ARGUMENT", "request must be an object") end
    local unknown_field = bounds.fields(object, {"thread_id", "cursor", "limit", "filter"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local thread_id, cursor = bounds.id(object.thread_id), bounds.cursor(object.cursor)
    if not thread_id then return failure("INVALID_ARGUMENT", "thread_id is not an identifier") end
    if not cursor then return failure("INVALID_ARGUMENT", "cursor must be between 0 and " .. tostring(bounds.MAX_THREAD_RECORDS)) end
    local limit = bounds.MAX_PAGE_RECORDS
    if object.limit ~= nil then
        local number = bounds.integer(object.limit)
        if not number or number < 1 or number > bounds.MAX_PAGE_RECORDS then return failure("INVALID_ARGUMENT", "limit must be between 1 and " .. tostring(bounds.MAX_PAGE_RECORDS)) end
        limit = number
    end
    local kinds: {string}? = nil
    local action_id: string? = nil
    if object.filter ~= nil then
        local filter = bounds.object(object.filter)
        if not filter then return failure("INVALID_ARGUMENT", "filter must be an object") end
        local unknown_filter = bounds.fields(filter, {"kinds", "action_id"})
        if unknown_filter then return failure("INVALID_ARGUMENT", unknown_filter) end
        if filter.kinds ~= nil then
            local list, list_error = bounds.ids(filter.kinds, true)
            if not list then return failure("INVALID_ARGUMENT", "kinds: " .. tostring(list_error)) end
            for _, item in ipairs(list) do
                if not values.kind(item) then return failure("INVALID_ARGUMENT", "kinds names an unsupported family") end
            end
            kinds = list
        end
        if filter.action_id ~= nil then
            local id = bounds.id(filter.action_id)
            if not id then return failure("INVALID_ARGUMENT", "action_id is not an identifier") end
            action_id = id
        end
    end
    return transaction.read(db, function(tx: sql.Transaction): Result
        local head, member, denied = M.membership(tx, thread_id, actor)
        if not head or not member then return denied or failure("DENIED", "caller is not a member of the thread") end
        local window_end = math.floor(math.min(cursor + SCAN_WINDOW, head.head_sequence))
        local rows, rows_err = reader.page(tx, thread_id, cursor, window_end, limit, kinds, action_id)
        if not rows then return storage(rows_err or "read thread records") end
        local records: {record_types.Record} = {}
        for index = 1, math.min(#rows, limit) do
            local decoded, decode_error = record.decode_json(rows[index].record_json)
            if not decoded then return failure("INTERNAL", decode_error or "stored record is corrupt") end
            records[index] = decoded
        end
        local has_more = #rows > limit
        local scanned_through = window_end
        if has_more then scanned_through = records[#records].sequence end
        if not has_more and window_end < head.head_sequence then has_more = true end
        return transaction.success({records = records, scanned_through = scanned_through, has_more = has_more}, false)
    end)
end
return M
