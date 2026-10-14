-- MIT. Destination plans: each staged version's measured candidate, artifact
-- and preflight report with its local review, the version selected per
-- source overlay, and the receipts that replay a plan mutation.
local STATEMENTS = {
    [[CREATE TABLE bee_governance_plans (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  source_node TEXT NOT NULL,
  source_workspace TEXT NOT NULL,
  version TEXT NOT NULL,
  candidate_bytes BLOB NOT NULL CHECK(length(CAST(candidate_bytes AS BLOB)) BETWEEN 1 AND 1048576),
  candidate_digest TEXT NOT NULL CHECK(length(candidate_digest) = 64),
  artifact_bytes BLOB NOT NULL CHECK(length(CAST(artifact_bytes AS BLOB)) BETWEEN 1 AND 262144),
  artifact_digest TEXT NOT NULL CHECK(length(artifact_digest) = 64),
  preflight_bytes BLOB NOT NULL CHECK(length(CAST(preflight_bytes AS BLOB)) BETWEEN 1 AND 131072),
  preflight_digest TEXT NOT NULL CHECK(length(preflight_digest) = 64),
  plan_digest TEXT NOT NULL CHECK(length(plan_digest) = 64),
  revision INTEGER NOT NULL CHECK(revision >= 1),
  status TEXT NOT NULL CHECK(status IN ('staged', 'reviewed', 'rejected')),
  review_status TEXT,
  review_reason TEXT CHECK(review_reason IS NULL OR length(CAST(review_reason AS BLOB)) <= 8192),
  reviewer_id TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY(owner_node, workspace_id, source_node, source_workspace, version),
  CHECK((status IN ('reviewed', 'rejected')) = (review_status IS NOT NULL)),
  CHECK(review_status IS NULL OR review_status IN ('accepted', 'rejected'))
)]],
    [[CREATE TABLE bee_governance_plan_slots (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  source_node TEXT NOT NULL,
  source_workspace TEXT NOT NULL,
  version TEXT NOT NULL,
  plan_revision INTEGER NOT NULL CHECK(plan_revision >= 1),
  selected_by TEXT NOT NULL,
  selected_at TEXT NOT NULL,
  PRIMARY KEY(owner_node, workspace_id, source_node, source_workspace),
  FOREIGN KEY(owner_node, workspace_id, source_node, source_workspace, version)
    REFERENCES bee_governance_plans(owner_node, workspace_id, source_node, source_workspace, version)
)]],
    [[CREATE TABLE bee_governance_plan_receipts (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  operation TEXT NOT NULL CHECK(operation IN ('stage', 'record_review', 'select')),
  request_digest TEXT NOT NULL CHECK(length(request_digest) = 64),
  source_node TEXT NOT NULL,
  source_workspace TEXT NOT NULL,
  version TEXT NOT NULL,
  result_revision INTEGER NOT NULL CHECK(result_revision >= 1),
  PRIMARY KEY(owner_node, workspace_id, idempotency_key),
  FOREIGN KEY(owner_node, workspace_id, source_node, source_workspace, version)
    REFERENCES bee_governance_plans(owner_node, workspace_id, source_node, source_workspace, version)
)]],
    "CREATE INDEX bee_governance_plans_list ON bee_governance_plans(owner_node, workspace_id, source_node, source_workspace, version)",
    "CREATE INDEX bee_governance_plans_status ON bee_governance_plans(owner_node, workspace_id, status)",
}

return require("migration").define(function()
    migration("Create governance destination plans", function()
        database("sqlite", function()
            up(function(db)
                for _, statement in ipairs(STATEMENTS) do
                    local _, err = db:execute(statement)
                    if err then error(err) end
                end
            end)
            down(function(db)
                for _, name in ipairs({"bee_governance_plan_receipts", "bee_governance_plan_slots", "bee_governance_plans"}) do
                    local _, err = db:execute("DROP TABLE IF EXISTS " .. name)
                    if err then error(err) end
                end
            end)
        end)
    end)
end)
