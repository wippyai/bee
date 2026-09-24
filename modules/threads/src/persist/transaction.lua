-- MIT. Thread transactions over the rich thread tables, sharing the busy
-- retry of bee.persist, plus the inserts every thread writer needs.
local sql = require("sql")
local time = require("time")
local uuid = require("uuid")
local shared = require("shared")
local M = {}
type Result = {ok: boolean, code: string?, message: string?, value: unknown, replayed: boolean}
type Body = (sql.Transaction) -> Result
type HeadInsert = {thread_id: string, owner_actor: string, title: string, created_at: string, workspace_id: string?}
type RecordInsert = {record_id: string, thread_id: string, sequence: integer, kind: string, producer_id: string, source: string,
    event_scope: string?, event_key: string?, action_id: string?, attempt_id: string?, turn_id: string?, record_json: string, committed_at: string}
-- Commitment instants are authority-generated canonical UTC.
function M.now(): string
    return time.now():utc():format("2006-01-02T15:04:05.000Z07:00")
end
function M.record_id(): (string?, string?)
    local id, err = uuid.v7()
    if err or not id then return nil, "allocate record identifier" end
    return id, nil
end
function M.storage_failure(message: string): Result
    return shared.storage_failure(message)
end
function M.failure(code: string, message: string): Result
    return shared.failure(code, message)
end
function M.success(value: unknown, replayed: boolean): Result
    return shared.success(value, replayed)
end
function M.write(db: sql.DB, body: Body): Result
    return shared.write(db, "thread", body)
end
function M.read(db: sql.DB, body: Body): Result
    return shared.read(db, "thread", body)
end
local function execute(tx: sql.Transaction, statement: string, params: {unknown}, what: string): string?
    local _, err = tx:execute(statement, params)
    if err then
        if shared.busy(err) then return "BUSY" end
        return what
    end
    return nil
end
function M.insert_head(tx: sql.Transaction, head: HeadInsert): string?
    return execute(tx, "INSERT INTO bee_thread_heads (thread_id, owner_actor, title, state, revision, head_sequence, created_at, workspace_id) VALUES (?, ?, ?, 'open', 1, 0, ?, ?)",
        {head.thread_id, head.owner_actor, head.title, head.created_at, head.workspace_id or sql.NULL}, "create thread head")
end
function M.insert_member(tx: sql.Transaction, thread_id: string, actor: string, role: string, revision: integer): string?
    return execute(tx, "INSERT INTO bee_thread_members (thread_id, actor, role, revision, active) VALUES (?, ?, ?, ?, 1)",
        {thread_id, actor, role, revision}, "add thread member")
end
function M.set_member(tx: sql.Transaction, thread_id: string, actor: string, role: string, revision: integer, active: boolean): string?
    return execute(tx, "UPDATE bee_thread_members SET role = ?, revision = ?, active = ? WHERE thread_id = ? AND actor = ?",
        {role, revision, active and 1 or 0, thread_id, actor}, "update thread member")
end
function M.set_revision(tx: sql.Transaction, thread_id: string, revision: integer, state: string): string?
    return execute(tx, "UPDATE bee_thread_heads SET revision = ?, state = ? WHERE thread_id = ?", {revision, state, thread_id}, "update thread head")
end
-- Advances the head and stores the record together; the UNIQUE sequence
-- constraint makes any interleaving visible as a failure, never a gap.
function M.insert_record(tx: sql.Transaction, record: RecordInsert): string?
    local head_err = execute(tx, "UPDATE bee_thread_heads SET head_sequence = ? WHERE thread_id = ? AND head_sequence = ?",
        {record.sequence, record.thread_id, record.sequence - 1}, "advance thread head")
    if head_err then return head_err end
    return execute(tx, "INSERT INTO bee_thread_records (record_id, thread_id, sequence, schema_revision, kind, producer_id, source, event_scope, event_key, " ..
        "action_id, attempt_id, turn_id, record_json, committed_at) VALUES (?, ?, ?, 'bee.thread-record@1', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        {record.record_id, record.thread_id, record.sequence, record.kind, record.producer_id, record.source,
            record.event_scope or sql.NULL, record.event_key or sql.NULL, record.action_id or sql.NULL, record.attempt_id or sql.NULL,
            record.turn_id or sql.NULL, record.record_json, record.committed_at}, "store thread record")
end
function M.insert_command(tx: sql.Transaction, thread_id: string, actor: string, key: string, operation: string, request_json: string, reply_json: string): string?
    return execute(tx, "INSERT INTO bee_thread_commands (thread_id, actor, idempotency_key, operation, request_json, reply_json) VALUES (?, ?, ?, ?, ?, ?)",
        {thread_id, actor, key, operation, request_json, reply_json}, "store thread command")
end
function M.insert_action(tx: sql.Transaction, thread_id: string, action_id: string, record_id: string): string?
    return execute(tx, "INSERT INTO bee_thread_actions (thread_id, action_id, admitted_record_id, state) VALUES (?, ?, ?, 'admitted')",
        {thread_id, action_id, record_id}, "index thread action")
end
function M.set_action_state(tx: sql.Transaction, thread_id: string, action_id: string, state: string): string?
    return execute(tx, "UPDATE bee_thread_actions SET state = ? WHERE thread_id = ? AND action_id = ?", {state, thread_id, action_id}, "update thread action")
end
function M.insert_attempt(tx: sql.Transaction, thread_id: string, attempt_id: string, action_id: string, record_id: string): string?
    return execute(tx, "INSERT INTO bee_thread_attempts (thread_id, attempt_id, action_id, prepared_record_id, state) VALUES (?, ?, ?, ?, 'prepared')",
        {thread_id, attempt_id, action_id, record_id}, "index thread attempt")
end
function M.start_attempt(tx: sql.Transaction, thread_id: string, attempt_id: string, owner_epoch: integer, record_id: string): string?
    return execute(tx, "UPDATE bee_thread_attempts SET owner_epoch = ?, started_record_id = ?, state = 'running' WHERE thread_id = ? AND attempt_id = ? AND state = 'prepared'",
        {owner_epoch, record_id, thread_id, attempt_id}, "start thread attempt")
end
function M.set_attempt_state(tx: sql.Transaction, thread_id: string, attempt_id: string, state: string): string?
    return execute(tx, "UPDATE bee_thread_attempts SET state = ? WHERE thread_id = ? AND attempt_id = ?", {state, thread_id, attempt_id}, "update thread attempt")
end
function M.insert_turn(tx: sql.Transaction, thread_id: string, turn_id: string, action_id: string, attempt_id: string, record_id: string): string?
    return execute(tx, "INSERT INTO bee_thread_turns (thread_id, turn_id, action_id, attempt_id, request_record_id) VALUES (?, ?, ?, ?, ?)",
        {thread_id, turn_id, action_id, attempt_id, record_id}, "index thread turn")
end
function M.end_turn(tx: sql.Transaction, thread_id: string, turn_id: string, record_id: string): string?
    return execute(tx, "UPDATE bee_thread_turns SET end_record_id = ? WHERE thread_id = ? AND turn_id = ? AND end_record_id IS NULL", {record_id, thread_id, turn_id}, "end thread turn")
end
function M.insert_settlement(tx: sql.Transaction, thread_id: string, scope: string, action_id: string, attempt_id: string?, outcome: string, record_id: string): string?
    return execute(tx, "INSERT INTO bee_thread_settlements (thread_id, action_id, attempt_id, scope, outcome, record_id) VALUES (?, ?, ?, ?, ?, ?)",
        {thread_id, action_id, attempt_id or sql.NULL, scope, outcome, record_id}, "index thread settlement")
end
function M.insert_obligation(tx: sql.Transaction, thread_id: string, message_id: string, recipient_id: string, record_id: string, kind: string, sequence: integer): string?
    return execute(tx, "INSERT INTO bee_thread_obligations (thread_id, message_id, recipient_id, message_record_id, kind, state, created_sequence) VALUES (?, ?, ?, ?, ?, 'pending', ?)",
        {thread_id, message_id, recipient_id, record_id, kind, sequence}, "create recipient obligation")
end
function M.set_obligation(tx: sql.Transaction, thread_id: string, message_id: string, recipient_id: string, state: string, delivery_id: string?): string?
    return execute(tx, "UPDATE bee_thread_obligations SET state = ?, delivery_id = ? WHERE thread_id = ? AND message_id = ? AND recipient_id = ?",
        {state, delivery_id or sql.NULL, thread_id, message_id, recipient_id}, "update recipient obligation")
end
function M.answer_obligation(tx: sql.Transaction, thread_id: string, message_id: string, recipient_id: string, reply_record_id: string, mark_record_id: string): string?
    return execute(tx, "UPDATE bee_thread_obligations SET state = 'answered', delivery_id = NULL, reply_record_id = ?, answered_mark_record_id = ? WHERE thread_id = ? AND message_id = ? AND recipient_id = ?",
        {reply_record_id, mark_record_id, thread_id, message_id, recipient_id}, "answer recipient obligation")
end
function M.set_delivery(tx: sql.Transaction, thread_id: string, delivery_id: string, state: string, mark_record_id: string, evidence_ref: string?): string?
    return execute(tx, "UPDATE bee_thread_deliveries SET state = ?, mark_record_id = ?, evidence_ref = COALESCE(?, evidence_ref) WHERE thread_id = ? AND delivery_id = ?",
        {state, mark_record_id, evidence_ref or sql.NULL, thread_id, delivery_id}, "update delivery")
end
function M.insert_batch(tx: sql.Transaction, batch_id: string, thread_id: string, actor: string, consumer_id: string, key: string, digest: string, turn_id: string?, attempt_id: string?, now: string): string?
    return execute(tx, "INSERT INTO bee_thread_claim_batches (batch_id, thread_id, claimant_actor, consumer_id, idempotency_key, request_digest, turn_id, attempt_id, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        {batch_id, thread_id, actor, consumer_id, key, digest, turn_id or sql.NULL, attempt_id or sql.NULL, now}, "create claim batch")
end
function M.insert_delivery(tx: sql.Transaction, thread_id: string, delivery_id: string, message_id: string, recipient_id: string, batch_id: string,
    consumer_id: string, channel: string, incarnation: integer, now: string, expires_at: string, mark_record_id: string): string?
    return execute(tx, "INSERT INTO bee_thread_deliveries (delivery_id, thread_id, message_id, recipient_id, batch_id, consumer_id, channel, owner_incarnation, state, claimed_at, expires_at, mark_record_id) " ..
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'claimed', ?, ?, ?)",
        {delivery_id, thread_id, message_id, recipient_id, batch_id, consumer_id, channel, incarnation, now, expires_at, mark_record_id}, "create delivery")
end
function M.insert_dispatch(tx: sql.Transaction, delivery_id: string, now: string, accepted: boolean, evidence_ref: string?): string?
    return execute(tx, "INSERT INTO bee_thread_dispatches (delivery_id, intent_at, accepted, evidence_ref) VALUES (?, ?, ?, ?)",
        {delivery_id, now, accepted and 1 or 0, evidence_ref or sql.NULL}, "record dispatch intent")
end
function M.insert_subscription(tx: sql.Transaction, subscription_id: string, thread_id: string, actor: string, consumer_id: string, digest: string, filter_json: string, durability: string, after: integer, incarnation: integer, now: string): string?
    return execute(tx, "INSERT INTO bee_thread_subscriptions (subscription_id, thread_id, actor, consumer_id, filter_digest, filter_json, durability, after_sequence, lease_generation, owner_incarnation, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)",
        {subscription_id, thread_id, actor, consumer_id, digest, filter_json, durability, after, incarnation, now}, "create subscription")
end
function M.insert_page(tx: sql.Transaction, page_id: string, subscription_id: string, generation: integer, from: integer, through: integer, digest: string, now: string): string?
    return execute(tx, "INSERT INTO bee_thread_subscription_pages (page_id, subscription_id, lease_generation, from_sequence, scanned_through, filter_digest, acknowledged, handed_at) VALUES (?, ?, ?, ?, ?, ?, 0, ?)",
        {page_id, subscription_id, generation, from, through, digest, now}, "hand out subscription page")
end
function M.set_page_through(tx: sql.Transaction, page_id: string, through: integer): string?
    return execute(tx, "UPDATE bee_thread_subscription_pages SET scanned_through = ? WHERE page_id = ?", {through, page_id}, "bound subscription page")
end
function M.ack_page(tx: sql.Transaction, page_id: string): string?
    return execute(tx, "UPDATE bee_thread_subscription_pages SET acknowledged = 1 WHERE page_id = ?", {page_id}, "acknowledge subscription page")
end
function M.set_subscription_cursor(tx: sql.Transaction, subscription_id: string, after: integer): string?
    return execute(tx, "UPDATE bee_thread_subscriptions SET after_sequence = ? WHERE subscription_id = ?", {after, subscription_id}, "advance subscription")
end
function M.close_subscription(tx: sql.Transaction, subscription_id: string, now: string): string?
    return execute(tx, "UPDATE bee_thread_subscriptions SET closed_at = ? WHERE subscription_id = ?", {now, subscription_id}, "close subscription")
end
function M.resume_subscription(tx: sql.Transaction, subscription_id: string, generation: integer, incarnation: integer): string?
    return execute(tx, "UPDATE bee_thread_subscriptions SET lease_generation = ?, owner_incarnation = ?, closed_at = NULL WHERE subscription_id = ?", {generation, incarnation, subscription_id}, "resume subscription")
end
-- An earlier lease's outstanding page is retired, never acknowledged.
function M.retire_pages(tx: sql.Transaction, subscription_id: string): string?
    return execute(tx, "UPDATE bee_thread_subscription_pages SET acknowledged = 1 WHERE subscription_id = ? AND acknowledged = 0", {subscription_id}, "retire subscription pages")
end
-- Forgets a subscription: its pages first for the foreign key, then the row.
-- Only a closed subscription is ever forgotten; the caller enforces that.
function M.delete_subscription_pages(tx: sql.Transaction, subscription_id: string): string?
    return execute(tx, "DELETE FROM bee_thread_subscription_pages WHERE subscription_id = ?", {subscription_id}, "forget subscription pages")
end
function M.delete_subscription(tx: sql.Transaction, subscription_id: string): string?
    return execute(tx, "DELETE FROM bee_thread_subscriptions WHERE subscription_id = ?", {subscription_id}, "forget subscription")
end
function M.write_projection(tx: sql.Transaction, thread_id: string, kind: string, through: integer, revision: integer, checkpoint_json: string, digest: string, now: string): string?
    return execute(tx, "INSERT INTO bee_thread_projections (thread_id, kind, through_sequence, revision, checkpoint_json, checkpoint_digest, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?) " ..
        "ON CONFLICT(thread_id, kind) DO UPDATE SET through_sequence = excluded.through_sequence, revision = excluded.revision, checkpoint_json = excluded.checkpoint_json, checkpoint_digest = excluded.checkpoint_digest, updated_at = excluded.updated_at",
        {thread_id, kind, through, revision, checkpoint_json, digest, now}, "write projection")
end
function M.drop_projection(tx: sql.Transaction, thread_id: string, kind: string): string?
    return execute(tx, "DELETE FROM bee_thread_projections WHERE thread_id = ? AND kind = ?", {thread_id, kind}, "drop projection")
end
function M.insert_notice(tx: sql.Transaction, notice_id: string, watcher_actor: string, watcher_thread_id: string, watcher_action_id: string?,
    target_thread_id: string, target_action_id: string, after: integer, now: string): string?
    return execute(tx, "INSERT INTO bee_thread_notices (notice_id, watcher_actor, watcher_thread_id, watcher_action_id, target_thread_id, target_action_id, after_sequence, state, created_at) " ..
        "VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?)",
        {notice_id, watcher_actor, watcher_thread_id, watcher_action_id or sql.NULL, target_thread_id, target_action_id, after, now}, "create thread notice")
end
function M.advance_notice(tx: sql.Transaction, notice_id: string, after: integer): string?
    return execute(tx, "UPDATE bee_thread_notices SET after_sequence = ? WHERE notice_id = ? AND state = 'pending'", {after, notice_id}, "advance thread notice")
end
function M.fire_notice(tx: sql.Transaction, notice_id: string, record_id: string): string?
    return execute(tx, "UPDATE bee_thread_notices SET state = 'fired', fired_record_id = ? WHERE notice_id = ? AND state = 'pending'", {record_id, notice_id}, "fire thread notice")
end
function M.cancel_notice(tx: sql.Transaction, notice_id: string): string?
    return execute(tx, "UPDATE bee_thread_notices SET state = 'cancelled' WHERE notice_id = ? AND state = 'pending'", {notice_id}, "cancel thread notice")
end
return M
