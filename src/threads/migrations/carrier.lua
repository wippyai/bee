-- MIT. Create the projection checkpoints, carrier epochs with their derived events, and
-- cancel intents.
local STATEMENTS = {
    [[CREATE TABLE bee_thread_projections (
  thread_id TEXT NOT NULL REFERENCES bee_thread_heads(thread_id),
  kind TEXT NOT NULL,
  through_sequence INTEGER NOT NULL CHECK(through_sequence >= 0),
  revision INTEGER NOT NULL CHECK(revision > 0),
  checkpoint_json TEXT NOT NULL,
  checkpoint_digest TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY(thread_id, kind)
)]],
    [[CREATE TABLE bee_thread_carriers (
  thread_id TEXT NOT NULL,
  attempt_id TEXT NOT NULL,
  carrier_epoch INTEGER NOT NULL CHECK(carrier_epoch > 0),
  checkpoint_revision INTEGER NOT NULL CHECK(checkpoint_revision >= 0),
  checkpoint_json TEXT CHECK(checkpoint_json IS NULL OR length(CAST(checkpoint_json AS BLOB)) <= 65536),
  updated_at TEXT NOT NULL,
  PRIMARY KEY(thread_id, attempt_id),
  FOREIGN KEY(thread_id, attempt_id) REFERENCES bee_thread_attempts(thread_id, attempt_id)
)]],
    [[CREATE TABLE bee_thread_carrier_events (
  thread_id TEXT NOT NULL,
  attempt_id TEXT NOT NULL,
  stream_id TEXT NOT NULL,
  envelope_index INTEGER NOT NULL CHECK(envelope_index >= 0),
  event_index INTEGER NOT NULL CHECK(event_index >= 0),
  source_first_sequence INTEGER NOT NULL CHECK(source_first_sequence >= 0),
  source_last_sequence INTEGER NOT NULL CHECK(source_last_sequence >= source_first_sequence),
  record_id TEXT NOT NULL UNIQUE REFERENCES bee_thread_records(record_id),
  PRIMARY KEY(thread_id, attempt_id, stream_id, envelope_index, event_index),
  FOREIGN KEY(thread_id, attempt_id) REFERENCES bee_thread_attempts(thread_id, attempt_id)
)]],
    [[CREATE TABLE bee_thread_cancel_intents (
  thread_id TEXT NOT NULL REFERENCES bee_thread_heads(thread_id),
  attempt_id TEXT NOT NULL,
  idempotency_key TEXT,
  state TEXT NOT NULL CHECK(state IN ('cancelling','ended')),
  outcome TEXT CHECK(outcome IS NULL OR outcome IN ('succeeded','failed','cancelled','uncertain')),
  recorded_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY(thread_id, attempt_id),
  CHECK((state = 'cancelling' AND outcome IS NULL) OR (state = 'ended' AND outcome = 'cancelled'))
)]],
}

return require("migration").define(function()
    migration("Create the projection checkpoints, carrier epochs with their derived events, and cancel intents", function()
        database("sqlite", function()
            up(function(db)
                for _, statement in ipairs(STATEMENTS) do
                    local _, err = db:execute(statement)
                    if err then error(err) end
                end
            end)
            down(function(db)
                for _, name in ipairs({"bee_thread_cancel_intents", "bee_thread_carrier_events", "bee_thread_carriers", "bee_thread_projections"}) do
                    local _, err = db:execute("DROP TABLE IF EXISTS " .. name)
                    if err then error(err) end
                end
            end)
        end)
    end)
end)
