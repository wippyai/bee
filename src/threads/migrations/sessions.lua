-- MIT. Create the session journal: sessions on their own threads, their
-- immutable work with its results, fenced turns, cancellations and the
-- operation receipts every mutation replays.
local STATEMENTS = {
    [[CREATE TABLE bee_sessions (
  session_ref TEXT PRIMARY KEY,
  thread_id TEXT NOT NULL UNIQUE REFERENCES bee_thread_heads(thread_id),
  workspace_id TEXT NOT NULL,
  owner_actor TEXT NOT NULL,
  title TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('active','suspended','closing','closed')),
  revision INTEGER NOT NULL CHECK(revision > 0),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  route_json TEXT NOT NULL DEFAULT '{}',
  context_json TEXT NOT NULL DEFAULT '{}',
  UNIQUE(session_ref, workspace_id)
)]],
    [[CREATE INDEX bee_sessions_workspace ON bee_sessions(workspace_id, state, created_at)]],
    [[CREATE TABLE bee_session_work (
  work_ref TEXT PRIMARY KEY,
  session_ref TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  sequence INTEGER NOT NULL CHECK(sequence > 0),
  revision INTEGER NOT NULL CHECK(revision > 0),
  phase TEXT NOT NULL CHECK(phase IN ('queued','reserved','accepted','settled')),
  input_json TEXT NOT NULL,
  input_digest TEXT NOT NULL,
  output_schema TEXT NOT NULL,
  sender_kind TEXT NOT NULL CHECK(sender_kind IN ('session','principal')),
  sender_id TEXT NOT NULL,
  result_json TEXT,
  uncertainty_json TEXT,
  operation_ref TEXT NOT NULL,
  created_at TEXT NOT NULL,
  UNIQUE(session_ref, sequence),
  UNIQUE(work_ref, session_ref),
  FOREIGN KEY(session_ref, workspace_id) REFERENCES bee_sessions(session_ref, workspace_id),
  CHECK((phase='settled') = (result_json IS NOT NULL))
)]],
    [[CREATE INDEX bee_session_work_queue ON bee_session_work(session_ref, phase, sequence)]],
    [[CREATE TABLE bee_session_turns (
  turn_ref TEXT PRIMARY KEY,
  session_ref TEXT NOT NULL REFERENCES bee_sessions(session_ref),
  work_ref TEXT NOT NULL UNIQUE,
  claim_token TEXT NOT NULL UNIQUE,
  owner_epoch INTEGER NOT NULL CHECK(owner_epoch > 0),
  input_digest TEXT NOT NULL,
  phase TEXT NOT NULL CHECK(phase IN ('reserved','accepted','settled')),
  checkpoint_json TEXT,
  reserve_record_id TEXT NOT NULL UNIQUE REFERENCES bee_thread_records(record_id),
  accept_record_id TEXT UNIQUE REFERENCES bee_thread_records(record_id),
  settle_record_id TEXT UNIQUE REFERENCES bee_thread_records(record_id),
  created_at TEXT NOT NULL,
  FOREIGN KEY(work_ref, session_ref) REFERENCES bee_session_work(work_ref, session_ref),
  CHECK((phase='reserved' AND accept_record_id IS NULL AND settle_record_id IS NULL)
     OR (phase='accepted' AND accept_record_id IS NOT NULL AND settle_record_id IS NULL)
     OR (phase='settled' AND accept_record_id IS NOT NULL AND settle_record_id IS NOT NULL))
)]],
    [[CREATE UNIQUE INDEX bee_session_live_turn ON bee_session_turns(session_ref) WHERE phase IN ('reserved','accepted')]],
    [[CREATE TABLE bee_session_work_cancellations (
  work_ref TEXT PRIMARY KEY REFERENCES bee_session_work(work_ref),
  operation_ref TEXT NOT NULL UNIQUE,
  reason TEXT,
  requested_at TEXT NOT NULL
)]],
    [[CREATE TABLE bee_session_operations (
  workspace_id TEXT NOT NULL,
  owner_actor TEXT NOT NULL,
  operation_key TEXT NOT NULL,
  operation_ref TEXT NOT NULL UNIQUE,
  operation TEXT NOT NULL,
  request_digest TEXT NOT NULL,
  target_ref TEXT,
  receipt_json TEXT NOT NULL,
  committed_at TEXT NOT NULL,
  PRIMARY KEY(workspace_id, owner_actor, operation_key)
)]],
}

return require("migration").define(function()
    migration("Create the session journal", function()
        database("sqlite", function()
            up(function(db)
                for _, statement in ipairs(STATEMENTS) do
                    local _, err = db:execute(statement)
                    if err then error(err) end
                end
            end)
            down(function(db)
                for _, name in ipairs({"bee_session_operations", "bee_session_work_cancellations", "bee_session_turns", "bee_session_work", "bee_sessions"}) do
                    local _, err = db:execute("DROP TABLE IF EXISTS " .. name)
                    if err then error(err) end
                end
            end)
        end)
    end)
end)
