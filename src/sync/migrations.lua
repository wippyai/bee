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
    return {{id = 1, name = "owner_local_feed", sql = INITIAL, rebuild = false},
        {id = 2, name = "source_qualified_version_replicas", rebuild = false, sql = [[
CREATE TABLE bee_sync_replica_sources (
  source_owner TEXT NOT NULL,
  feed TEXT NOT NULL,
  cursor INTEGER NOT NULL CHECK(cursor >= 0),
  PRIMARY KEY(source_owner, feed)
);
CREATE TABLE bee_sync_replica_versions (
  source_owner TEXT NOT NULL,
  feed TEXT NOT NULL,
  version_key TEXT NOT NULL,
  descriptor_digest TEXT NOT NULL CHECK(length(descriptor_digest) = 64),
  descriptor_json TEXT NOT NULL CHECK(length(CAST(descriptor_json AS BLOB)) <= 16384),
  PRIMARY KEY(source_owner, feed, version_key),
  FOREIGN KEY(source_owner, feed) REFERENCES bee_sync_replica_sources(source_owner, feed)
);
]]},
        {id = 3, name = "resumable_replica_content", rebuild = false, sql = [[
CREATE TABLE bee_sync_replica_transfers (
  source_owner TEXT NOT NULL,
  feed TEXT NOT NULL,
  version_key TEXT NOT NULL,
  descriptor_digest TEXT NOT NULL CHECK(length(descriptor_digest) = 64),
  descriptor_json TEXT NOT NULL CHECK(length(CAST(descriptor_json AS BLOB)) <= 16384),
  content_digest TEXT NOT NULL CHECK(length(content_digest) = 64),
  total_bytes INTEGER NOT NULL CHECK(total_bytes BETWEEN 0 AND 16777216),
  received_bytes INTEGER NOT NULL CHECK(received_bytes BETWEEN 0 AND total_bytes),
  source_cursor INTEGER NOT NULL CHECK(source_cursor >= 0),
  state TEXT NOT NULL CHECK(state IN ('receiving', 'available')),
  PRIMARY KEY(source_owner, feed, version_key),
  FOREIGN KEY(source_owner, feed) REFERENCES bee_sync_replica_sources(source_owner, feed)
);
CREATE TABLE bee_sync_replica_chunks (
  source_owner TEXT NOT NULL,
  feed TEXT NOT NULL,
  version_key TEXT NOT NULL,
  byte_offset INTEGER NOT NULL CHECK(byte_offset >= 0),
  byte_count INTEGER NOT NULL CHECK(byte_count BETWEEN 0 AND 32768),
  content_sha256 TEXT NOT NULL CHECK(length(content_sha256) = 64),
  content_base64 TEXT NOT NULL CHECK(length(CAST(content_base64 AS BLOB)) <= 43692),
  PRIMARY KEY(source_owner, feed, version_key, byte_offset),
  FOREIGN KEY(source_owner, feed, version_key)
    REFERENCES bee_sync_replica_transfers(source_owner, feed, version_key)
);
CREATE INDEX bee_sync_replica_chunks_order
  ON bee_sync_replica_chunks(source_owner, feed, version_key, byte_offset);
]]},
        {id = 4, name = "destination_distribution_cursors", rebuild = false, sql = [[
CREATE TABLE bee_sync_distribution_cursors (
  source_owner TEXT NOT NULL,
  feed TEXT NOT NULL,
  destination_node TEXT NOT NULL,
  cursor INTEGER NOT NULL CHECK(cursor >= 0),
  PRIMARY KEY(source_owner, feed, destination_node)
);
]]}}
end
return M
