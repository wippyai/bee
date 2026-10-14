-- MIT. Create thread heads, members, records and the work lifecycle. Records are stored as
-- their canonical envelope; extracted columns mirror it.
local STATEMENTS = {
    [[CREATE TABLE bee_thread_heads (
  thread_id TEXT PRIMARY KEY,
  owner_actor TEXT NOT NULL,
  title TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('open','closed')),
  revision INTEGER NOT NULL CHECK(revision > 0),
  head_sequence INTEGER NOT NULL DEFAULT 0 CHECK(head_sequence >= 0),
  created_at TEXT NOT NULL,
  workspace_id TEXT CHECK(workspace_id IS NULL OR length(CAST(workspace_id AS BLOB)) BETWEEN 1 AND 160)
)]],
    [[CREATE INDEX bee_thread_heads_workspace ON bee_thread_heads(workspace_id, thread_id) WHERE workspace_id IS NOT NULL]],
    [[CREATE TABLE bee_thread_members (
  thread_id TEXT NOT NULL REFERENCES bee_thread_heads(thread_id),
  actor TEXT NOT NULL,
  role TEXT NOT NULL CHECK(role IN ('owner','participant','observer')),
  revision INTEGER NOT NULL CHECK(revision > 0),
  active INTEGER NOT NULL CHECK(active IN (0,1)),
  PRIMARY KEY(thread_id, actor)
)]],
    [[CREATE UNIQUE INDEX bee_thread_one_owner ON bee_thread_members(thread_id) WHERE role='owner' AND active=1]],
    [[CREATE INDEX bee_thread_member_list ON bee_thread_members(actor, active, thread_id)]],
    [[CREATE TABLE bee_thread_records (
  record_id TEXT PRIMARY KEY,
  thread_id TEXT NOT NULL REFERENCES bee_thread_heads(thread_id),
  sequence INTEGER NOT NULL CHECK(sequence > 0),
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
  record_json TEXT NOT NULL CHECK(length(CAST(record_json AS BLOB)) <= 16384),
  committed_at TEXT NOT NULL,
  CHECK((event_scope IS NULL AND event_key IS NULL) OR (event_scope IS NOT NULL AND event_key IS NOT NULL)),
  UNIQUE(thread_id, sequence),
  UNIQUE(thread_id, producer_id, event_scope, event_key)
)]],
    [[CREATE INDEX bee_thread_records_kind ON bee_thread_records(thread_id, kind, sequence)]],
    [[CREATE INDEX bee_thread_records_action ON bee_thread_records(thread_id, action_id, sequence)]],
    [[CREATE TABLE bee_thread_commands (
  thread_id TEXT NOT NULL REFERENCES bee_thread_heads(thread_id),
  actor TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  operation TEXT NOT NULL,
  request_json TEXT NOT NULL,
  reply_json TEXT NOT NULL,
  PRIMARY KEY(thread_id, actor, idempotency_key)
)]],
    [[CREATE TABLE bee_thread_actions (
  thread_id TEXT NOT NULL REFERENCES bee_thread_heads(thread_id),
  action_id TEXT NOT NULL,
  admitted_record_id TEXT NOT NULL UNIQUE REFERENCES bee_thread_records(record_id),
  state TEXT NOT NULL CHECK(state IN ('admitted','running','ended')),
  PRIMARY KEY(thread_id, action_id)
)]],
    [[CREATE TABLE bee_thread_attempts (
  thread_id TEXT NOT NULL,
  attempt_id TEXT NOT NULL,
  action_id TEXT NOT NULL,
  owner_epoch INTEGER CHECK(owner_epoch > 0),
  prepared_record_id TEXT UNIQUE REFERENCES bee_thread_records(record_id),
  started_record_id TEXT UNIQUE REFERENCES bee_thread_records(record_id),
  state TEXT NOT NULL CHECK(state IN ('prepared','running','ended')),
  PRIMARY KEY(thread_id, attempt_id),
  UNIQUE(thread_id, action_id, attempt_id),
  FOREIGN KEY(thread_id, action_id) REFERENCES bee_thread_actions(thread_id, action_id),
  CHECK((state = 'prepared' AND started_record_id IS NULL AND owner_epoch IS NULL)
     OR (state = 'running' AND started_record_id IS NOT NULL AND owner_epoch IS NOT NULL)
     OR (state = 'ended' AND (started_record_id IS NULL) = (owner_epoch IS NULL)))
)]],
    [[CREATE UNIQUE INDEX bee_thread_live_attempt ON bee_thread_attempts(thread_id, action_id) WHERE state IN ('prepared','running')]],
    [[CREATE TABLE bee_thread_turns (
  thread_id TEXT NOT NULL,
  turn_id TEXT NOT NULL,
  action_id TEXT NOT NULL,
  attempt_id TEXT NOT NULL,
  request_record_id TEXT NOT NULL UNIQUE REFERENCES bee_thread_records(record_id),
  end_record_id TEXT UNIQUE REFERENCES bee_thread_records(record_id),
  PRIMARY KEY(thread_id, turn_id),
  FOREIGN KEY(thread_id, action_id, attempt_id) REFERENCES bee_thread_attempts(thread_id, action_id, attempt_id)
)]],
    [[CREATE UNIQUE INDEX bee_thread_live_turn ON bee_thread_turns(thread_id, attempt_id) WHERE end_record_id IS NULL]],
    [[CREATE TABLE bee_thread_settlements (
  thread_id TEXT NOT NULL,
  action_id TEXT NOT NULL,
  attempt_id TEXT,
  scope TEXT NOT NULL CHECK(scope IN ('action','attempt')),
  outcome TEXT NOT NULL CHECK(outcome IN ('succeeded','failed','cancelled','uncertain')),
  record_id TEXT NOT NULL UNIQUE REFERENCES bee_thread_records(record_id),
  CHECK((scope='action' AND attempt_id IS NULL) OR (scope='attempt' AND attempt_id IS NOT NULL)),
  FOREIGN KEY(thread_id, action_id) REFERENCES bee_thread_actions(thread_id, action_id),
  FOREIGN KEY(thread_id, action_id, attempt_id) REFERENCES bee_thread_attempts(thread_id, action_id, attempt_id)
)]],
    [[CREATE UNIQUE INDEX bee_thread_action_receipt ON bee_thread_settlements(thread_id, action_id) WHERE scope='action']],
    [[CREATE UNIQUE INDEX bee_thread_attempt_receipt ON bee_thread_settlements(thread_id, attempt_id) WHERE scope='attempt']],
}

return require("migration").define(function()
    migration("Create thread heads, members, records and the work lifecycle", function()
        database("sqlite", function()
            up(function(db)
                for _, statement in ipairs(STATEMENTS) do
                    local _, err = db:execute(statement)
                    if err then error(err) end
                end
            end)
            down(function(db)
                for _, name in ipairs({"bee_thread_settlements", "bee_thread_turns", "bee_thread_attempts", "bee_thread_actions", "bee_thread_commands", "bee_thread_records", "bee_thread_members", "bee_thread_heads"}) do
                    local _, err = db:execute("DROP TABLE IF EXISTS " .. name)
                    if err then error(err) end
                end
            end)
        end)
    end)
end)
