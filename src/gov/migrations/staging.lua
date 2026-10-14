-- MIT. The authoring store: each author's private overlays, their mutable
-- files, the frozen snapshots copied out of them and the receipts that replay
-- a mutation. Snapshot files duplicate overlay files on purpose: a frozen
-- candidate survives later edits and restarts and is never rebuilt from a
-- mutable overlay.
local STATEMENTS = {
    [[CREATE TABLE bee_governance_workspaces (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK(revision >= 1),
  PRIMARY KEY(owner_node, workspace_id)
)]],
    [[CREATE TABLE bee_governance_workspace_files (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  path TEXT NOT NULL,
  content_base64 TEXT NOT NULL CHECK(length(CAST(content_base64 AS BLOB)) <= 5592408),
  content_sha256 TEXT NOT NULL CHECK(length(content_sha256) = 64),
  bytes INTEGER NOT NULL CHECK(bytes BETWEEN 0 AND 4194304),
  PRIMARY KEY(owner_node, workspace_id, path),
  FOREIGN KEY(owner_node, workspace_id) REFERENCES bee_governance_workspaces(owner_node, workspace_id)
)]],
    [[CREATE TABLE bee_governance_snapshots (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  digest TEXT NOT NULL CHECK(length(digest) = 64),
  revision INTEGER NOT NULL CHECK(revision >= 1),
  files_digest TEXT NOT NULL CHECK(length(files_digest) = 64),
  file_count INTEGER NOT NULL CHECK(file_count BETWEEN 0 AND 256),
  total_bytes INTEGER NOT NULL CHECK(total_bytes BETWEEN 0 AND 16777216),
  PRIMARY KEY(owner_node, workspace_id, digest),
  FOREIGN KEY(owner_node, workspace_id) REFERENCES bee_governance_workspaces(owner_node, workspace_id)
)]],
    [[CREATE TABLE bee_governance_snapshot_files (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  snapshot_digest TEXT NOT NULL,
  path TEXT NOT NULL,
  content_base64 TEXT NOT NULL CHECK(length(CAST(content_base64 AS BLOB)) <= 5592408),
  content_sha256 TEXT NOT NULL CHECK(length(content_sha256) = 64),
  bytes INTEGER NOT NULL CHECK(bytes BETWEEN 0 AND 4194304),
  PRIMARY KEY(owner_node, workspace_id, snapshot_digest, path),
  FOREIGN KEY(owner_node, workspace_id, snapshot_digest)
    REFERENCES bee_governance_snapshots(owner_node, workspace_id, digest)
)]],
    [[CREATE TABLE bee_governance_receipts (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  operation TEXT NOT NULL,
  expected_revision INTEGER NOT NULL CHECK(expected_revision >= 0),
  path TEXT,
  content_sha256 TEXT,
  result_revision INTEGER NOT NULL CHECK(result_revision >= 1),
  snapshot_digest TEXT,
  files_digest TEXT,
  file_count INTEGER,
  total_bytes INTEGER,
  PRIMARY KEY(owner_node, workspace_id, idempotency_key),
  FOREIGN KEY(owner_node, workspace_id) REFERENCES bee_governance_workspaces(owner_node, workspace_id),
  CHECK(operation IN ('create', 'put', 'append', 'remove', 'freeze')),
  CHECK((operation IN ('put', 'append') AND path IS NOT NULL AND content_sha256 IS NOT NULL)
    OR (operation = 'remove' AND path IS NOT NULL AND content_sha256 IS NULL)
    OR (operation IN ('create', 'freeze') AND path IS NULL AND content_sha256 IS NULL)),
  CHECK((operation = 'freeze' AND snapshot_digest IS NOT NULL AND files_digest IS NOT NULL
      AND file_count IS NOT NULL AND total_bytes IS NOT NULL)
    OR (operation <> 'freeze' AND snapshot_digest IS NULL AND files_digest IS NULL
      AND file_count IS NULL AND total_bytes IS NULL))
)]],
    "CREATE INDEX bee_governance_workspaces_node ON bee_governance_workspaces(owner_node)",
    "CREATE INDEX bee_governance_workspace_files_list ON bee_governance_workspace_files(owner_node, workspace_id, path)",
}

return require("migration").define(function()
    migration("Create governance authoring overlays and frozen snapshots", function()
        database("sqlite", function()
            up(function(db)
                for _, statement in ipairs(STATEMENTS) do
                    local _, err = db:execute(statement)
                    if err then error(err) end
                end
            end)
            down(function(db)
                for _, name in ipairs({"bee_governance_receipts", "bee_governance_snapshot_files", "bee_governance_snapshots",
                    "bee_governance_workspace_files", "bee_governance_workspaces"}) do
                    local _, err = db:execute("DROP TABLE IF EXISTS " .. name)
                    if err then error(err) end
                end
            end)
        end)
    end)
end)
