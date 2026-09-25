-- MIT. The owned schema as an ordered ledger. Migration text is part of its
-- checksum: a change here is a new migration, never an edit.
-- rebuild marks a migration that recreates a table: it runs with foreign key
-- enforcement off on the migration connection and is checked before commit.
type Migration = {id: integer, name: string, sql: string, rebuild: boolean}
local M = {}

local THREAD_SCHEMA_SQL = [[
CREATE TABLE IF NOT EXISTS bee_threads (
    thread_id TEXT PRIMARY KEY,
    actor TEXT NOT NULL,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS bee_thread_runs (
    thread_id TEXT NOT NULL,
    run_id TEXT NOT NULL,
    actor TEXT NOT NULL,
    claimed_at TEXT NOT NULL,
    PRIMARY KEY (thread_id, run_id),
    FOREIGN KEY (thread_id) REFERENCES bee_threads(thread_id)
);
CREATE TABLE IF NOT EXISTS bee_thread_events (
    thread_id TEXT NOT NULL,
    sequence INTEGER NOT NULL CHECK (sequence > 0),
    run_id TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    event_type TEXT NOT NULL,
    body_json TEXT NOT NULL,
    committed_at TEXT NOT NULL,
    PRIMARY KEY (thread_id, sequence),
    UNIQUE (thread_id, run_id, idempotency_key),
    FOREIGN KEY (thread_id, run_id) REFERENCES bee_thread_runs(thread_id, run_id)
)
]]

local THREAD_AUTHORITY_SQL = [[
CREATE TABLE bee_thread_heads (
  thread_id TEXT PRIMARY KEY,
  owner_actor TEXT NOT NULL,
  title TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('open','closed')),
  revision INTEGER NOT NULL CHECK(revision > 0),
  head_sequence INTEGER NOT NULL DEFAULT 0
    CHECK(head_sequence BETWEEN 0 AND 10000),
  created_at TEXT NOT NULL
);
CREATE TABLE bee_thread_members (
  thread_id TEXT NOT NULL REFERENCES bee_thread_heads(thread_id),
  actor TEXT NOT NULL,
  role TEXT NOT NULL CHECK(role IN ('owner','participant','observer')),
  revision INTEGER NOT NULL CHECK(revision > 0),
  active INTEGER NOT NULL CHECK(active IN (0,1)),
  PRIMARY KEY(thread_id, actor)
);
CREATE UNIQUE INDEX bee_thread_one_owner
  ON bee_thread_members(thread_id) WHERE role='owner' AND active=1;
CREATE INDEX bee_thread_member_list
  ON bee_thread_members(actor, active, thread_id);
CREATE TABLE bee_thread_records (
  record_id TEXT PRIMARY KEY,
  thread_id TEXT NOT NULL REFERENCES bee_thread_heads(thread_id),
  sequence INTEGER NOT NULL CHECK(sequence BETWEEN 1 AND 10000),
  schema_revision TEXT NOT NULL CHECK(schema_revision='bee.thread-record@1'),
  kind TEXT NOT NULL CHECK(kind IN (
    'observation','message','action.admitted','attempt.started',
    'turn.request','turn.end','receipt')),
  producer_id TEXT NOT NULL,
  source TEXT NOT NULL CHECK(source IN ('stream','hook','transcript','mcp','bee')),
  event_scope TEXT,
  event_key TEXT,
  action_id TEXT,
  attempt_id TEXT,
  turn_id TEXT,
  record_json TEXT NOT NULL
    CHECK(length(CAST(record_json AS BLOB)) <= 16384),
  committed_at TEXT NOT NULL,
  CHECK((event_scope IS NULL AND event_key IS NULL)
     OR (event_scope IS NOT NULL AND event_key IS NOT NULL)),
  UNIQUE(thread_id, sequence),
  UNIQUE(thread_id, producer_id, event_scope, event_key)
);
CREATE INDEX bee_thread_records_kind
  ON bee_thread_records(thread_id, kind, sequence);
CREATE INDEX bee_thread_records_action
  ON bee_thread_records(thread_id, action_id, sequence);
CREATE TABLE bee_thread_commands (
  thread_id TEXT NOT NULL REFERENCES bee_thread_heads(thread_id),
  actor TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  operation TEXT NOT NULL,
  request_json TEXT NOT NULL,
  reply_json TEXT NOT NULL,
  PRIMARY KEY(thread_id, actor, idempotency_key)
)
]]

local WORK_LIFECYCLE_SQL = [[
CREATE TABLE bee_thread_actions (
  thread_id TEXT NOT NULL REFERENCES bee_thread_heads(thread_id),
  action_id TEXT NOT NULL,
  admitted_record_id TEXT NOT NULL UNIQUE REFERENCES bee_thread_records(record_id),
  state TEXT NOT NULL CHECK(state IN ('admitted','running','ended')),
  PRIMARY KEY(thread_id, action_id)
);
CREATE TABLE bee_thread_attempts (
  thread_id TEXT NOT NULL,
  attempt_id TEXT NOT NULL,
  action_id TEXT NOT NULL,
  owner_epoch INTEGER NOT NULL CHECK(owner_epoch > 0),
  started_record_id TEXT NOT NULL UNIQUE REFERENCES bee_thread_records(record_id),
  state TEXT NOT NULL CHECK(state IN ('running','ended')),
  PRIMARY KEY(thread_id, attempt_id),
  UNIQUE(thread_id, action_id, attempt_id),
  FOREIGN KEY(thread_id, action_id)
    REFERENCES bee_thread_actions(thread_id, action_id)
);
CREATE UNIQUE INDEX bee_thread_live_attempt
  ON bee_thread_attempts(thread_id, action_id) WHERE state='running';
CREATE TABLE bee_thread_turns (
  thread_id TEXT NOT NULL,
  turn_id TEXT NOT NULL,
  action_id TEXT NOT NULL,
  attempt_id TEXT NOT NULL,
  request_record_id TEXT NOT NULL UNIQUE REFERENCES bee_thread_records(record_id),
  end_record_id TEXT UNIQUE REFERENCES bee_thread_records(record_id),
  PRIMARY KEY(thread_id, turn_id),
  FOREIGN KEY(thread_id, action_id, attempt_id)
    REFERENCES bee_thread_attempts(thread_id, action_id, attempt_id)
);
CREATE UNIQUE INDEX bee_thread_live_turn
  ON bee_thread_turns(thread_id, attempt_id) WHERE end_record_id IS NULL;
CREATE TABLE bee_thread_settlements (
  thread_id TEXT NOT NULL,
  action_id TEXT NOT NULL,
  attempt_id TEXT,
  scope TEXT NOT NULL CHECK(scope IN ('action','attempt')),
  outcome TEXT NOT NULL CHECK(outcome IN
    ('succeeded','failed','cancelled','uncertain')),
  record_id TEXT NOT NULL UNIQUE REFERENCES bee_thread_records(record_id),
  CHECK((scope='action' AND attempt_id IS NULL)
     OR (scope='attempt' AND attempt_id IS NOT NULL)),
  FOREIGN KEY(thread_id, action_id)
    REFERENCES bee_thread_actions(thread_id, action_id),
  FOREIGN KEY(thread_id, action_id, attempt_id)
    REFERENCES bee_thread_attempts(thread_id, action_id, attempt_id)
);
CREATE UNIQUE INDEX bee_thread_action_receipt
  ON bee_thread_settlements(thread_id, action_id) WHERE scope='action';
CREATE UNIQUE INDEX bee_thread_attempt_receipt
  ON bee_thread_settlements(thread_id, attempt_id) WHERE scope='attempt'
]]

local DELIVERY_SQL = [[
CREATE TABLE bee_thread_records_rebuilt (
  record_id TEXT PRIMARY KEY,
  thread_id TEXT NOT NULL REFERENCES bee_thread_heads(thread_id),
  sequence INTEGER NOT NULL CHECK(sequence BETWEEN 1 AND 10000),
  schema_revision TEXT NOT NULL CHECK(schema_revision='bee.thread-record@1'),
  kind TEXT NOT NULL CHECK(kind IN (
    'observation','message','action.admitted','attempt.started',
    'turn.request','turn.end','receipt','delivery.mark','request.answered')),
  producer_id TEXT NOT NULL,
  source TEXT NOT NULL CHECK(source IN ('stream','hook','transcript','mcp','bee')),
  event_scope TEXT,
  event_key TEXT,
  action_id TEXT,
  attempt_id TEXT,
  turn_id TEXT,
  record_json TEXT NOT NULL
    CHECK(length(CAST(record_json AS BLOB)) <= 16384),
  committed_at TEXT NOT NULL,
  CHECK((event_scope IS NULL AND event_key IS NULL)
     OR (event_scope IS NOT NULL AND event_key IS NOT NULL)),
  UNIQUE(thread_id, sequence),
  UNIQUE(thread_id, producer_id, event_scope, event_key)
);
INSERT INTO bee_thread_records_rebuilt (record_id, thread_id, sequence, schema_revision, kind, producer_id, source,
  event_scope, event_key, action_id, attempt_id, turn_id, record_json, committed_at)
  SELECT record_id, thread_id, sequence, schema_revision, kind, producer_id, source,
  event_scope, event_key, action_id, attempt_id, turn_id, record_json, committed_at FROM bee_thread_records;
DROP TABLE bee_thread_records;
ALTER TABLE bee_thread_records_rebuilt RENAME TO bee_thread_records;
CREATE INDEX bee_thread_records_kind
  ON bee_thread_records(thread_id, kind, sequence);
CREATE INDEX bee_thread_records_action
  ON bee_thread_records(thread_id, action_id, sequence);
CREATE TABLE bee_thread_owner (
  singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
  incarnation INTEGER NOT NULL CHECK(incarnation > 0),
  started_at TEXT NOT NULL
);
CREATE TABLE bee_thread_obligations (
  thread_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  recipient_id TEXT NOT NULL,
  message_record_id TEXT NOT NULL REFERENCES bee_thread_records(record_id),
  kind TEXT NOT NULL CHECK(kind IN ('request','progress','reply','notification')),
  state TEXT NOT NULL CHECK(state IN ('pending','claimed','delivered','answered','uncertain','abandoned')),
  delivery_id TEXT,
  reply_record_id TEXT REFERENCES bee_thread_records(record_id),
  answered_mark_record_id TEXT REFERENCES bee_thread_records(record_id),
  created_sequence INTEGER NOT NULL CHECK(created_sequence BETWEEN 1 AND 10000),
  PRIMARY KEY(thread_id, message_id, recipient_id),
  FOREIGN KEY(thread_id) REFERENCES bee_thread_heads(thread_id)
);
CREATE INDEX bee_thread_obligations_recipient
  ON bee_thread_obligations(thread_id, recipient_id, state, created_sequence);
CREATE TABLE bee_thread_claim_batches (
  batch_id TEXT PRIMARY KEY,
  thread_id TEXT NOT NULL REFERENCES bee_thread_heads(thread_id),
  claimant_actor TEXT NOT NULL,
  consumer_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  request_digest TEXT NOT NULL,
  turn_id TEXT,
  attempt_id TEXT,
  created_at TEXT NOT NULL,
  UNIQUE(thread_id, claimant_actor, consumer_id, idempotency_key)
);
CREATE TABLE bee_thread_deliveries (
  delivery_id TEXT PRIMARY KEY,
  thread_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  recipient_id TEXT NOT NULL,
  batch_id TEXT NOT NULL REFERENCES bee_thread_claim_batches(batch_id),
  consumer_id TEXT NOT NULL,
  channel TEXT NOT NULL,
  owner_incarnation INTEGER NOT NULL CHECK(owner_incarnation > 0),
  state TEXT NOT NULL CHECK(state IN ('claimed','delivered','released','uncertain')),
  claimed_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  evidence_ref TEXT,
  mark_record_id TEXT NOT NULL REFERENCES bee_thread_records(record_id),
  UNIQUE(batch_id, thread_id, message_id, recipient_id),
  FOREIGN KEY(thread_id, message_id, recipient_id)
    REFERENCES bee_thread_obligations(thread_id, message_id, recipient_id)
);
CREATE UNIQUE INDEX bee_thread_live_delivery
  ON bee_thread_deliveries(thread_id, message_id, recipient_id) WHERE state='claimed';
CREATE TABLE bee_thread_dispatches (
  delivery_id TEXT PRIMARY KEY REFERENCES bee_thread_deliveries(delivery_id),
  intent_at TEXT NOT NULL,
  accepted INTEGER NOT NULL CHECK(accepted IN (0,1)),
  evidence_ref TEXT
);
CREATE TABLE bee_thread_subscriptions (
  subscription_id TEXT PRIMARY KEY,
  thread_id TEXT NOT NULL REFERENCES bee_thread_heads(thread_id),
  actor TEXT NOT NULL,
  consumer_id TEXT NOT NULL,
  filter_digest TEXT NOT NULL,
  filter_json TEXT NOT NULL,
  durability TEXT NOT NULL CHECK(durability IN ('durable','reconstructible')),
  after_sequence INTEGER NOT NULL CHECK(after_sequence BETWEEN 0 AND 10000),
  lease_generation INTEGER NOT NULL CHECK(lease_generation > 0),
  owner_incarnation INTEGER NOT NULL CHECK(owner_incarnation > 0),
  created_at TEXT NOT NULL,
  closed_at TEXT
);
CREATE UNIQUE INDEX bee_thread_subscription_identity
  ON bee_thread_subscriptions(thread_id, actor, consumer_id, filter_digest) WHERE closed_at IS NULL;
CREATE TABLE bee_thread_subscription_pages (
  page_id TEXT PRIMARY KEY,
  subscription_id TEXT NOT NULL REFERENCES bee_thread_subscriptions(subscription_id),
  lease_generation INTEGER NOT NULL CHECK(lease_generation > 0),
  from_sequence INTEGER NOT NULL CHECK(from_sequence BETWEEN 0 AND 10000),
  scanned_through INTEGER NOT NULL CHECK(scanned_through BETWEEN 0 AND 10000),
  filter_digest TEXT NOT NULL,
  acknowledged INTEGER NOT NULL CHECK(acknowledged IN (0,1)),
  handed_at TEXT NOT NULL
);
CREATE UNIQUE INDEX bee_thread_outstanding_page
  ON bee_thread_subscription_pages(subscription_id) WHERE acknowledged=0
]]

local PROJECTION_SQL = [[
CREATE TABLE bee_thread_projections (
  thread_id TEXT NOT NULL REFERENCES bee_thread_heads(thread_id),
  kind TEXT NOT NULL,
  through_sequence INTEGER NOT NULL CHECK(through_sequence BETWEEN 0 AND 10000),
  revision INTEGER NOT NULL CHECK(revision > 0),
  checkpoint_json TEXT NOT NULL,
  checkpoint_digest TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY(thread_id, kind)
)
]]

local CARRIER_SQL = [[
CREATE TABLE bee_thread_records_rebuilt (
  record_id TEXT PRIMARY KEY,
  thread_id TEXT NOT NULL REFERENCES bee_thread_heads(thread_id),
  sequence INTEGER NOT NULL CHECK(sequence BETWEEN 1 AND 10000),
  schema_revision TEXT NOT NULL CHECK(schema_revision='bee.thread-record@1'),
  kind TEXT NOT NULL CHECK(kind IN (
    'observation','message','action.admitted','attempt.prepared','attempt.started',
    'turn.request','turn.end','receipt','delivery.mark','request.answered')),
  producer_id TEXT NOT NULL,
  source TEXT NOT NULL CHECK(source IN ('stream','hook','transcript','mcp','bee')),
  event_scope TEXT,
  event_key TEXT,
  action_id TEXT,
  attempt_id TEXT,
  turn_id TEXT,
  record_json TEXT NOT NULL
    CHECK(length(CAST(record_json AS BLOB)) <= 16384),
  committed_at TEXT NOT NULL,
  CHECK((event_scope IS NULL AND event_key IS NULL)
     OR (event_scope IS NOT NULL AND event_key IS NOT NULL)),
  UNIQUE(thread_id, sequence),
  UNIQUE(thread_id, producer_id, event_scope, event_key)
);
INSERT INTO bee_thread_records_rebuilt (record_id, thread_id, sequence, schema_revision, kind, producer_id, source,
  event_scope, event_key, action_id, attempt_id, turn_id, record_json, committed_at)
  SELECT record_id, thread_id, sequence, schema_revision, kind, producer_id, source,
  event_scope, event_key, action_id, attempt_id, turn_id, record_json, committed_at FROM bee_thread_records;
DROP TABLE bee_thread_records;
ALTER TABLE bee_thread_records_rebuilt RENAME TO bee_thread_records;
CREATE INDEX bee_thread_records_kind
  ON bee_thread_records(thread_id, kind, sequence);
CREATE INDEX bee_thread_records_action
  ON bee_thread_records(thread_id, action_id, sequence);
CREATE TABLE bee_thread_attempts_rebuilt (
  thread_id TEXT NOT NULL,
  attempt_id TEXT NOT NULL,
  action_id TEXT NOT NULL,
  owner_epoch INTEGER CHECK(owner_epoch > 0),
  prepared_record_id TEXT UNIQUE REFERENCES bee_thread_records(record_id),
  started_record_id TEXT UNIQUE REFERENCES bee_thread_records(record_id),
  state TEXT NOT NULL CHECK(state IN ('prepared','running','ended')),
  PRIMARY KEY(thread_id, attempt_id),
  UNIQUE(thread_id, action_id, attempt_id),
  FOREIGN KEY(thread_id, action_id)
    REFERENCES bee_thread_actions(thread_id, action_id),
  CHECK((state = 'prepared' AND started_record_id IS NULL AND owner_epoch IS NULL)
     OR (state = 'running' AND started_record_id IS NOT NULL AND owner_epoch IS NOT NULL)
     OR (state = 'ended' AND (started_record_id IS NULL) = (owner_epoch IS NULL)))
);
INSERT INTO bee_thread_attempts_rebuilt (thread_id, attempt_id, action_id, owner_epoch, prepared_record_id, started_record_id, state)
  SELECT thread_id, attempt_id, action_id, owner_epoch, NULL, started_record_id, state FROM bee_thread_attempts;
DROP TABLE bee_thread_attempts;
ALTER TABLE bee_thread_attempts_rebuilt RENAME TO bee_thread_attempts;
CREATE UNIQUE INDEX bee_thread_live_attempt
  ON bee_thread_attempts(thread_id, action_id) WHERE state IN ('prepared','running');
CREATE TABLE bee_thread_carriers (
  thread_id TEXT NOT NULL,
  attempt_id TEXT NOT NULL,
  carrier_epoch INTEGER NOT NULL CHECK(carrier_epoch > 0),
  checkpoint_revision INTEGER NOT NULL CHECK(checkpoint_revision >= 0),
  checkpoint_json TEXT CHECK(checkpoint_json IS NULL OR length(CAST(checkpoint_json AS BLOB)) <= 65536),
  updated_at TEXT NOT NULL,
  PRIMARY KEY(thread_id, attempt_id),
  FOREIGN KEY(thread_id, attempt_id)
    REFERENCES bee_thread_attempts(thread_id, attempt_id)
);
CREATE TABLE bee_thread_carrier_events (
  thread_id TEXT NOT NULL,
  attempt_id TEXT NOT NULL,
  stream_id TEXT NOT NULL,
  envelope_index INTEGER NOT NULL CHECK(envelope_index >= 0),
  event_index INTEGER NOT NULL CHECK(event_index >= 0),
  source_first_sequence INTEGER NOT NULL CHECK(source_first_sequence >= 0),
  source_last_sequence INTEGER NOT NULL CHECK(source_last_sequence >= source_first_sequence),
  record_id TEXT NOT NULL UNIQUE REFERENCES bee_thread_records(record_id),
  PRIMARY KEY(thread_id, attempt_id, stream_id, envelope_index, event_index),
  FOREIGN KEY(thread_id, attempt_id)
    REFERENCES bee_thread_attempts(thread_id, attempt_id)
);
]]
local APPROVALS_SQL = [[
CREATE TABLE bee_thread_records_rebuilt (
  record_id TEXT PRIMARY KEY,
  thread_id TEXT NOT NULL REFERENCES bee_thread_heads(thread_id),
  sequence INTEGER NOT NULL CHECK(sequence BETWEEN 1 AND 10000),
  schema_revision TEXT NOT NULL CHECK(schema_revision='bee.thread-record@1'),
  kind TEXT NOT NULL CHECK(kind IN (
    'observation','message','action.admitted','attempt.prepared','attempt.started',
    'turn.request','turn.end','receipt','delivery.mark','request.answered',
    'approval.request','approval.transition')),
  producer_id TEXT NOT NULL,
  source TEXT NOT NULL CHECK(source IN ('stream','hook','transcript','mcp','bee')),
  event_scope TEXT,
  event_key TEXT,
  action_id TEXT,
  attempt_id TEXT,
  turn_id TEXT,
  record_json TEXT NOT NULL
    CHECK(length(CAST(record_json AS BLOB)) <= 16384),
  committed_at TEXT NOT NULL,
  CHECK((event_scope IS NULL AND event_key IS NULL)
     OR (event_scope IS NOT NULL AND event_key IS NOT NULL)),
  UNIQUE(thread_id, sequence),
  UNIQUE(thread_id, producer_id, event_scope, event_key)
);
INSERT INTO bee_thread_records_rebuilt (record_id, thread_id, sequence, schema_revision, kind, producer_id, source,
  event_scope, event_key, action_id, attempt_id, turn_id, record_json, committed_at)
  SELECT record_id, thread_id, sequence, schema_revision, kind, producer_id, source,
  event_scope, event_key, action_id, attempt_id, turn_id, record_json, committed_at FROM bee_thread_records;
DROP TABLE bee_thread_records;
ALTER TABLE bee_thread_records_rebuilt RENAME TO bee_thread_records;
CREATE INDEX bee_thread_records_kind
  ON bee_thread_records(thread_id, kind, sequence);
CREATE INDEX bee_thread_records_action
  ON bee_thread_records(thread_id, action_id, sequence);
]]
local OWNER_AUTHORITY_SQL = [[
ALTER TABLE bee_thread_owner ADD COLUMN authority_id TEXT;
]]
-- A notice is owed once to a watcher on its own thread when a target action
-- ends a turn or an attempt; after_sequence is the scan cursor over that
-- action's records on the target thread.
local NOTICES_SQL = [[
CREATE TABLE bee_thread_notices (
  notice_id TEXT PRIMARY KEY,
  watcher_actor TEXT NOT NULL,
  watcher_thread_id TEXT NOT NULL REFERENCES bee_thread_heads(thread_id),
  watcher_action_id TEXT,
  target_thread_id TEXT NOT NULL,
  target_action_id TEXT NOT NULL,
  after_sequence INTEGER NOT NULL CHECK(after_sequence >= 0),
  state TEXT NOT NULL CHECK(state IN ('pending','fired','cancelled')),
  fired_record_id TEXT REFERENCES bee_thread_records(record_id),
  created_at TEXT NOT NULL,
  CHECK((state = 'fired') = (fired_record_id IS NOT NULL)),
  FOREIGN KEY(target_thread_id, target_action_id)
    REFERENCES bee_thread_actions(thread_id, action_id)
);
CREATE INDEX bee_thread_notices_target
  ON bee_thread_notices(target_thread_id, state);
CREATE INDEX bee_thread_notices_watcher
  ON bee_thread_notices(watcher_thread_id, state);
]]
-- A thread a workspace owns carries that workspace. Threads created before
-- this migration are attributed from their owner: an application principal
-- is bee.application:<workspace_id>:<instance_id>. Other threads stay
-- node-level. The partial index makes a workspace's threads one index range.
local WORKSPACE_SQL = [[
ALTER TABLE bee_thread_heads ADD COLUMN workspace_id TEXT
  CHECK(workspace_id IS NULL OR (length(workspace_id) = 32 AND workspace_id NOT GLOB '*[^0-9a-f]*'));
UPDATE bee_thread_heads SET workspace_id = substr(owner_actor, 17, 32)
  WHERE substr(owner_actor, 1, 16) = 'bee.application:' AND substr(owner_actor, 49, 1) = ':'
    AND length(owner_actor) > 49 AND substr(owner_actor, 17, 32) NOT GLOB '*[^0-9a-f]*';
CREATE INDEX bee_thread_heads_workspace
  ON bee_thread_heads(workspace_id, thread_id) WHERE workspace_id IS NOT NULL;
]]
-- An action owns a separately ordered inbox. Acceptance revisions fence
-- addresses handed out before an owner changes its allow list. Delivery
-- states beyond committed are reserved for later carrier integration.
local ACTION_INBOX_SQL = [[
CREATE TABLE bee_thread_inbox_epochs (
  thread_id TEXT NOT NULL,
  action_id TEXT NOT NULL,
  grant_epoch INTEGER NOT NULL CHECK(grant_epoch > 0),
  next_sequence INTEGER NOT NULL DEFAULT 1 CHECK(next_sequence > 0),
  PRIMARY KEY(thread_id, action_id),
  FOREIGN KEY(thread_id, action_id) REFERENCES bee_thread_actions(thread_id, action_id)
);
CREATE TABLE bee_thread_inbox_rules (
  thread_id TEXT NOT NULL,
  action_id TEXT NOT NULL,
  sender_kind TEXT NOT NULL CHECK(sender_kind IN ('actor','class')),
  sender_value TEXT NOT NULL,
  PRIMARY KEY(thread_id, action_id, sender_kind, sender_value),
  FOREIGN KEY(thread_id, action_id) REFERENCES bee_thread_inbox_epochs(thread_id, action_id)
);
CREATE TABLE bee_thread_inbox_items (
  thread_id TEXT NOT NULL,
  action_id TEXT NOT NULL,
  inbox_sequence INTEGER NOT NULL CHECK(inbox_sequence > 0),
  record_id TEXT NOT NULL UNIQUE REFERENCES bee_thread_records(record_id),
  payload_digest TEXT NOT NULL CHECK(length(payload_digest) = 64),
  sender_actor TEXT NOT NULL,
  sender_action_id TEXT NOT NULL,
  sender_node_id TEXT NOT NULL,
  sender_thread_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('committed','offered','transport_accepted','acknowledged','replied')),
  in_reply_to_thread_id TEXT,
  in_reply_to_record_id TEXT,
  reply_thread_id TEXT,
  reply_record_id TEXT,
  PRIMARY KEY(thread_id, action_id, inbox_sequence),
  FOREIGN KEY(thread_id, action_id) REFERENCES bee_thread_inbox_epochs(thread_id, action_id),
  CHECK((in_reply_to_thread_id IS NULL) = (in_reply_to_record_id IS NULL)),
  CHECK((reply_thread_id IS NULL) = (reply_record_id IS NULL))
);
CREATE INDEX bee_thread_inbox_sender ON bee_thread_inbox_items(sender_actor, sender_action_id, record_id);
]]
-- An offer belongs to one carrier generation. Reclaiming it under a newer
-- generation preserves the inbox record and its digest for agent deduplication.
local ACTION_INBOX_PUSH_SQL = [[
ALTER TABLE bee_thread_inbox_items ADD COLUMN offer_attempt_id TEXT;
ALTER TABLE bee_thread_inbox_items ADD COLUMN offer_carrier_epoch INTEGER;
ALTER TABLE bee_thread_inbox_items ADD COLUMN offer_count INTEGER NOT NULL DEFAULT 0 CHECK(offer_count >= 0);
ALTER TABLE bee_thread_inbox_items ADD COLUMN offered_at TEXT;
ALTER TABLE bee_thread_inbox_items ADD COLUMN transport_accepted_at TEXT;
]]
-- Delivery blockers are distinct from receipt progression: a queued item
-- keeps its committed state and identity until an admitted controller offers it.
local ACTION_INBOX_DELIVERY_STATUS_SQL = [[
ALTER TABLE bee_thread_inbox_items ADD COLUMN delivery_block TEXT CHECK(delivery_block IN ('waiting_for_restart','undeliverable'));
]]
-- The durable forwarding outbox: one row per cross-node send, keyed by the
-- sender's own thread, actor and idempotency key, so a retried send replays
-- the row instead of duplicating it. A pump leases due rows, delivers each
-- through the destination's admission, and settles only on the destination
-- reply; the destination deduplicates on its own idempotency key, so a lost
-- reply repeats the delivery rather than duplicating the message.
local ACTION_INBOX_OUTBOX_SQL = [[
CREATE TABLE bee_thread_inbox_outbox (
  outbox_id TEXT NOT NULL PRIMARY KEY,
  sender_thread_id TEXT NOT NULL,
  sender_actor TEXT NOT NULL,
  sender_action_id TEXT NOT NULL,
  sender_node_id TEXT NOT NULL,
  dest_node_id TEXT NOT NULL,
  dest_workspace_id TEXT NOT NULL,
  dest_thread_id TEXT NOT NULL,
  dest_action_id TEXT NOT NULL,
  grant_epoch INTEGER NOT NULL CHECK(grant_epoch > 0),
  idempotency_key TEXT NOT NULL,
  message_id TEXT NOT NULL,
  content_json TEXT NOT NULL,
  payload_digest TEXT NOT NULL CHECK(length(payload_digest) = 64),
  state TEXT NOT NULL CHECK(state IN ('queued','delivered','failed','exhausted')) DEFAULT 'queued',
  attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts >= 0),
  next_attempt_ms INTEGER NOT NULL DEFAULT 0,
  lease_owner TEXT,
  lease_until_ms INTEGER,
  last_error TEXT,
  receipt_json TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(sender_thread_id, sender_actor, idempotency_key)
);
CREATE INDEX bee_thread_inbox_outbox_due ON bee_thread_inbox_outbox(state, next_attempt_ms);
]]
local list: {Migration} = {
    {id = 1, name = "bee_thread_schema_v1", sql = THREAD_SCHEMA_SQL, rebuild = false},
    {id = 2, name = "thread_authority", sql = THREAD_AUTHORITY_SQL, rebuild = false},
    {id = 3, name = "work_lifecycle", sql = WORK_LIFECYCLE_SQL, rebuild = false},
    {id = 4, name = "delivery", sql = DELIVERY_SQL, rebuild = true},
    {id = 5, name = "projection", sql = PROJECTION_SQL, rebuild = false},
    {id = 6, name = "carrier", sql = CARRIER_SQL, rebuild = true},
    {id = 7, name = "approvals", sql = APPROVALS_SQL, rebuild = true},
    {id = 8, name = "owner_authority", sql = OWNER_AUTHORITY_SQL, rebuild = false},
    {id = 9, name = "notices", sql = NOTICES_SQL, rebuild = false},
    {id = 10, name = "workspace_attribution", sql = WORKSPACE_SQL, rebuild = false},
    {id = 11, name = "action_inbox", sql = ACTION_INBOX_SQL, rebuild = false},
    {id = 12, name = "action_inbox_push", sql = ACTION_INBOX_PUSH_SQL, rebuild = false},
    {id = 13, name = "action_inbox_delivery_status", sql = ACTION_INBOX_DELIVERY_STATUS_SQL, rebuild = false},
    {id = 14, name = "action_inbox_outbox", sql = ACTION_INBOX_OUTBOX_SQL, rebuild = false},
}
function M.all(): {Migration}
    return M.prefix(#list)
end
-- The first `count` migrations; tests open a store at an earlier revision.
function M.prefix(count: integer): {Migration}
    local result: {Migration} = {}
    for index = 1, count do result[index] = list[index] end
    return result
end
return M
