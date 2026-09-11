-- MIT. Immutable schema ledger for the owner-local synchronized projection.
local M = {}
type Migration = {id: integer, name: string, sql: string, rebuild: boolean}
local INITIAL = [[
CREATE TABLE bee_sync_feeds (
  owner_id TEXT NOT NULL,
  feed TEXT NOT NULL,
  head_sequence INTEGER NOT NULL CHECK(head_sequence >= 0),
  earliest_sequence INTEGER NOT NULL CHECK(earliest_sequence >= 1),
  event_capacity INTEGER NOT NULL CHECK(event_capacity BETWEEN 1 AND 1024),
  receipt_capacity INTEGER NOT NULL CHECK(receipt_capacity BETWEEN 1 AND 8192),
  PRIMARY KEY(owner_id, feed)
);
CREATE TABLE bee_sync_projections (
  owner_id TEXT NOT NULL,
  feed TEXT NOT NULL,
  projection_key TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK(revision > 0),
  value_json TEXT,
  tombstone INTEGER NOT NULL CHECK(tombstone IN (0,1)),
  last_sequence INTEGER NOT NULL CHECK(last_sequence > 0),
  updated_at TEXT NOT NULL,
  PRIMARY KEY(owner_id, feed, projection_key),
  FOREIGN KEY(owner_id, feed) REFERENCES bee_sync_feeds(owner_id, feed),
  CHECK((tombstone = 1 AND value_json IS NULL) OR (tombstone = 0 AND value_json IS NOT NULL)),
  CHECK(value_json IS NULL OR length(CAST(value_json AS BLOB)) <= 16384)
);
CREATE TABLE bee_sync_events (
  owner_id TEXT NOT NULL,
  feed TEXT NOT NULL,
  sequence INTEGER NOT NULL CHECK(sequence > 0),
  event_id TEXT NOT NULL,
  event_type TEXT NOT NULL,
  payload_json TEXT NOT NULL CHECK(length(CAST(payload_json AS BLOB)) <= 16384),
  projection_key TEXT NOT NULL,
  projection_revision INTEGER NOT NULL CHECK(projection_revision > 0),
  tombstone INTEGER NOT NULL CHECK(tombstone IN (0,1)),
  committed_at TEXT NOT NULL,
  PRIMARY KEY(owner_id, feed, sequence),
  UNIQUE(owner_id, feed, event_id),
  FOREIGN KEY(owner_id, feed, projection_key) REFERENCES bee_sync_projections(owner_id, feed, projection_key)
);
CREATE TABLE bee_sync_receipts (
  owner_id TEXT NOT NULL,
  feed TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  event_id TEXT NOT NULL,
  request_json TEXT NOT NULL CHECK(length(CAST(request_json AS BLOB)) <= 16384),
  sequence INTEGER NOT NULL CHECK(sequence > 0),
  projection_key TEXT NOT NULL,
  projection_revision INTEGER NOT NULL CHECK(projection_revision > 0),
  PRIMARY KEY(owner_id, feed, idempotency_key),
  UNIQUE(owner_id, feed, event_id),
  FOREIGN KEY(owner_id, feed) REFERENCES bee_sync_feeds(owner_id, feed)
);
CREATE INDEX bee_sync_events_window ON bee_sync_events(owner_id, feed, sequence);
CREATE INDEX bee_sync_projection_snapshot ON bee_sync_projections(owner_id, feed, projection_key);
]]
function M.all(): {Migration}
    return {{id = 1, name = "owner_local_feed", sql = INITIAL, rebuild = false}}
end
return M
