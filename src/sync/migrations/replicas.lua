-- MIT. Source-qualified replicas of immutable versions with their resumable
-- content, each source feed's discovery cursor, and how far each destination
-- received this node's distributed feeds.
local STATEMENTS = {
    [[CREATE TABLE bee_sync_replica_sources (
  source_owner TEXT NOT NULL,
  feed TEXT NOT NULL,
  cursor INTEGER NOT NULL CHECK(cursor >= 0),
  PRIMARY KEY(source_owner, feed)
)]],
    [[CREATE TABLE bee_sync_replica_versions (
  source_owner TEXT NOT NULL,
  feed TEXT NOT NULL,
  version_key TEXT NOT NULL,
  descriptor_digest TEXT NOT NULL CHECK(length(descriptor_digest) = 64),
  descriptor_json TEXT NOT NULL CHECK(length(CAST(descriptor_json AS BLOB)) <= 16384),
  PRIMARY KEY(source_owner, feed, version_key),
  FOREIGN KEY(source_owner, feed) REFERENCES bee_sync_replica_sources(source_owner, feed)
)]],
    [[CREATE TABLE bee_sync_replica_transfers (
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
)]],
    [[CREATE TABLE bee_sync_replica_chunks (
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
)]],
    "CREATE INDEX bee_sync_replica_chunks_order ON bee_sync_replica_chunks(source_owner, feed, version_key, byte_offset)",
    [[CREATE TABLE bee_sync_distribution_cursors (
  source_owner TEXT NOT NULL,
  feed TEXT NOT NULL,
  destination TEXT NOT NULL,
  cursor INTEGER NOT NULL CHECK(cursor >= 0),
  PRIMARY KEY(source_owner, feed, destination)
)]],
}

return require("migration").define(function()
    migration("Create sync replicas and distribution cursors", function()
        database("sqlite", function()
            up(function(db)
                for _, statement in ipairs(STATEMENTS) do
                    local _, err = db:execute(statement)
                    if err then error(err) end
                end
            end)
            down(function(db)
                for _, name in ipairs({"bee_sync_distribution_cursors", "bee_sync_replica_chunks", "bee_sync_replica_transfers",
                    "bee_sync_replica_versions", "bee_sync_replica_sources"}) do
                    local _, err = db:execute("DROP TABLE IF EXISTS " .. name)
                    if err then error(err) end
                end
            end)
        end)
    end)
end)
