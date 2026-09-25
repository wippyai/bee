-- MIT. Immutable schema for the governance-owned, node-local authoring store.
local M = {}

type Migration = {id: integer, name: string, sql: string, rebuild: boolean}

-- Snapshot files deliberately duplicate workspace files.  A frozen candidate
-- must survive both later edits and a service restart, and it must never be
-- reconstructed from a mutable workspace.
local INITIAL = [[
CREATE TABLE bee_governance_workspaces (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK(revision >= 1),
  PRIMARY KEY(owner_node, workspace_id)
);
CREATE TABLE bee_governance_workspace_files (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  path TEXT NOT NULL,
  content_base64 TEXT NOT NULL CHECK(length(CAST(content_base64 AS BLOB)) <= 5592408),
  content_sha256 TEXT NOT NULL CHECK(length(content_sha256) = 64),
  bytes INTEGER NOT NULL CHECK(bytes BETWEEN 0 AND 4194304),
  PRIMARY KEY(owner_node, workspace_id, path),
  FOREIGN KEY(owner_node, workspace_id) REFERENCES bee_governance_workspaces(owner_node, workspace_id)
);
CREATE TABLE bee_governance_snapshots (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  digest TEXT NOT NULL CHECK(length(digest) = 64),
  revision INTEGER NOT NULL CHECK(revision >= 1),
  files_digest TEXT NOT NULL CHECK(length(files_digest) = 64),
  file_count INTEGER NOT NULL CHECK(file_count BETWEEN 0 AND 256),
  total_bytes INTEGER NOT NULL CHECK(total_bytes BETWEEN 0 AND 16777216),
  PRIMARY KEY(owner_node, workspace_id, digest),
  FOREIGN KEY(owner_node, workspace_id) REFERENCES bee_governance_workspaces(owner_node, workspace_id)
);
CREATE TABLE bee_governance_snapshot_files (
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
);
CREATE TABLE bee_governance_receipts (
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
  CHECK(operation IN ('create', 'put', 'remove', 'freeze')),
  CHECK((operation = 'put' AND path IS NOT NULL AND content_sha256 IS NOT NULL)
    OR (operation = 'remove' AND path IS NOT NULL AND content_sha256 IS NULL)
    OR (operation IN ('create', 'freeze') AND path IS NULL AND content_sha256 IS NULL)),
  CHECK((operation = 'freeze' AND snapshot_digest IS NOT NULL AND files_digest IS NOT NULL
      AND file_count IS NOT NULL AND total_bytes IS NOT NULL)
    OR (operation <> 'freeze' AND snapshot_digest IS NULL AND files_digest IS NULL
      AND file_count IS NULL AND total_bytes IS NULL))
);
CREATE INDEX bee_governance_workspaces_node ON bee_governance_workspaces(owner_node);
CREATE INDEX bee_governance_workspace_files_list ON bee_governance_workspace_files(owner_node, workspace_id, path);
]]

local PLANS_SQL = [[
CREATE TABLE bee_governance_plans (
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
  status TEXT NOT NULL CHECK(status IN ('staged', 'reviewed', 'rejected', 'approval_bound')),
  review_status TEXT,
  review_reason TEXT CHECK(review_reason IS NULL OR length(CAST(review_reason AS BLOB)) <= 8192),
  reviewer_id TEXT,
  approval_id TEXT,
  approval_digest TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY(owner_node, workspace_id, source_node, source_workspace, version),
  CHECK((status IN ('reviewed', 'rejected', 'approval_bound')) = (review_status IS NOT NULL)),
  CHECK(review_status IS NULL OR review_status IN ('accepted', 'rejected')),
  CHECK((status = 'approval_bound') = (approval_id IS NOT NULL)),
  CHECK(approval_digest IS NULL OR length(approval_digest) = 64)
);
CREATE TABLE bee_governance_plan_selection (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  source_node TEXT NOT NULL,
  source_workspace TEXT NOT NULL,
  version TEXT NOT NULL,
  plan_revision INTEGER NOT NULL CHECK(plan_revision >= 1),
  selected_by TEXT NOT NULL,
  selected_at TEXT NOT NULL,
  PRIMARY KEY(owner_node, workspace_id),
  FOREIGN KEY(owner_node, workspace_id, source_node, source_workspace, version)
    REFERENCES bee_governance_plans(owner_node, workspace_id, source_node, source_workspace, version)
);
CREATE TABLE bee_governance_plan_receipts (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  operation TEXT NOT NULL CHECK(operation IN ('stage', 'record_review', 'select', 'bind_approval')),
  request_digest TEXT NOT NULL CHECK(length(request_digest) = 64),
  source_node TEXT NOT NULL,
  source_workspace TEXT NOT NULL,
  version TEXT NOT NULL,
  result_revision INTEGER NOT NULL CHECK(result_revision >= 1),
  PRIMARY KEY(owner_node, workspace_id, idempotency_key),
  FOREIGN KEY(owner_node, workspace_id, source_node, source_workspace, version)
    REFERENCES bee_governance_plans(owner_node, workspace_id, source_node, source_workspace, version)
);
CREATE INDEX bee_governance_plans_list
  ON bee_governance_plans(owner_node, workspace_id, source_node, source_workspace, version);
CREATE INDEX bee_governance_plans_status
  ON bee_governance_plans(owner_node, workspace_id, status);
]]

local APPROVAL_PROPOSAL_SQL = [[
ALTER TABLE bee_governance_plans ADD COLUMN approval_proposal_digest TEXT
  CHECK(approval_proposal_digest IS NULL OR length(approval_proposal_digest) = 64);
]]

local APPROVAL_INCARNATION_SQL = [[
ALTER TABLE bee_governance_plans ADD COLUMN approval_owner_incarnation INTEGER
  CHECK(approval_owner_incarnation IS NULL OR approval_owner_incarnation >= 1);
]]

-- Activation is destination-owned. The intent is immutable installation
-- evidence. Mutable approval/execution progress lives in a separate row, and
-- the slot keeps the authorized recovery target separate from observation.
local ACTIVATION_SQL = [[
CREATE TABLE bee_governance_activation_intents (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  intent_id TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  overlay_owner TEXT NOT NULL,
  source_node TEXT NOT NULL,
  source_workspace TEXT NOT NULL,
  version TEXT NOT NULL,
  plan_digest TEXT NOT NULL CHECK(length(plan_digest) = 64),
  plan_revision INTEGER NOT NULL CHECK(plan_revision >= 1),
  selection_revision INTEGER NOT NULL CHECK(selection_revision >= 1),
  artifact_bytes BLOB NOT NULL CHECK(length(CAST(artifact_bytes AS BLOB)) BETWEEN 1 AND 262144),
  artifact_digest TEXT NOT NULL CHECK(length(artifact_digest) = 64),
  resolution_bytes BLOB NOT NULL CHECK(length(CAST(resolution_bytes AS BLOB)) BETWEEN 1 AND 1048576),
  resolution_digest TEXT NOT NULL CHECK(length(resolution_digest) = 64),
  preflight_bytes BLOB NOT NULL CHECK(length(CAST(preflight_bytes AS BLOB)) BETWEEN 1 AND 131072),
  preflight_digest TEXT NOT NULL CHECK(length(preflight_digest) = 64),
  authorization_digest TEXT NOT NULL CHECK(length(authorization_digest) = 64),
  effect_key TEXT NOT NULL CHECK(length(effect_key) = 64),
  created_at TEXT NOT NULL,
  PRIMARY KEY(owner_node, workspace_id, intent_id),
  UNIQUE(owner_node, workspace_id, effect_key)
);
CREATE TABLE bee_governance_activation_execution (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  intent_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK(revision >= 1),
  phase TEXT NOT NULL CHECK(phase IN ('prepared', 'approval_bound', 'consuming', 'authorized', 'applying', 'settled')),
  approval_id TEXT,
  approval_proposal_digest TEXT CHECK(approval_proposal_digest IS NULL OR length(approval_proposal_digest) = 64),
  approval_owner_incarnation INTEGER CHECK(approval_owner_incarnation IS NULL OR approval_owner_incarnation >= 1),
  consumed_consumer_id TEXT,
  consumed_proposal_digest TEXT CHECK(consumed_proposal_digest IS NULL OR length(consumed_proposal_digest) = 64),
  consumed_effect_key TEXT,
  outcome TEXT CHECK(outcome IS NULL OR outcome IN ('applied', 'blocked', 'failed', 'uncertain')),
  diagnostics TEXT CHECK(diagnostics IS NULL OR length(CAST(diagnostics AS BLOB)) <= 8192),
  updated_at TEXT NOT NULL,
  PRIMARY KEY(owner_node, workspace_id, intent_id),
  FOREIGN KEY(owner_node, workspace_id, intent_id) REFERENCES bee_governance_activation_intents(owner_node, workspace_id, intent_id),
  CHECK((((phase IN ('approval_bound', 'consuming', 'authorized', 'applying', 'settled')) AND approval_id IS NOT NULL) OR ((phase = 'prepared') AND approval_id IS NULL))),
  CHECK((((phase IN ('authorized', 'applying', 'settled')) AND consumed_consumer_id IS NOT NULL AND consumed_proposal_digest IS NOT NULL AND consumed_effect_key IS NOT NULL) OR ((phase IN ('prepared', 'approval_bound', 'consuming')) AND consumed_consumer_id IS NULL AND consumed_proposal_digest IS NULL AND consumed_effect_key IS NULL))),
  CHECK(((phase = 'settled') AND outcome IS NOT NULL) OR ((phase <> 'settled') AND outcome IS NULL))
);
CREATE TABLE bee_governance_activation_slot (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK(revision >= 0),
  desired_intent_id TEXT,
  desired_execution_revision INTEGER CHECK(desired_execution_revision IS NULL OR desired_execution_revision >= 1),
  observed_intent_id TEXT,
  observed_execution_revision INTEGER CHECK(observed_execution_revision IS NULL OR observed_execution_revision >= 1),
  observed_artifact_digest TEXT CHECK(observed_artifact_digest IS NULL OR length(observed_artifact_digest) = 64),
  observed_outcome TEXT CHECK(observed_outcome IS NULL OR observed_outcome IN ('applied', 'blocked', 'failed', 'uncertain')),
  updated_at TEXT NOT NULL,
  PRIMARY KEY(owner_node, workspace_id),
  FOREIGN KEY(owner_node, workspace_id, desired_intent_id) REFERENCES bee_governance_activation_intents(owner_node, workspace_id, intent_id),
  FOREIGN KEY(owner_node, workspace_id, observed_intent_id) REFERENCES bee_governance_activation_intents(owner_node, workspace_id, intent_id),
  CHECK((desired_intent_id IS NULL) = (desired_execution_revision IS NULL)),
  CHECK((observed_intent_id IS NULL) = (observed_execution_revision IS NULL))
);
CREATE TABLE bee_governance_activation_receipts (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  operation TEXT NOT NULL CHECK(operation IN ('prepare_activation', 'bind_approval', 'begin_consume', 'record_consumption', 'begin_apply', 'record_outcome')),
  request_digest TEXT NOT NULL CHECK(length(request_digest) = 64),
  intent_id TEXT NOT NULL,
  result_revision INTEGER NOT NULL CHECK(result_revision >= 1),
  PRIMARY KEY(owner_node, workspace_id, idempotency_key),
  FOREIGN KEY(owner_node, workspace_id, intent_id) REFERENCES bee_governance_activation_intents(owner_node, workspace_id, intent_id)
);
CREATE INDEX bee_governance_activation_phase ON bee_governance_activation_execution(owner_node, workspace_id, phase);
]]

-- Installation state is scoped by the application it controls.  The original
-- tables retained one selection and one activation pointer for an entire
-- workspace, so installing a second application displaced the first.  Keep
-- the old tables as upgrade evidence and copy their single rows into the new
-- component-scoped tables.
local COMPONENT_SLOTS_SQL = [[
CREATE TABLE bee_governance_plan_slots (
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
);
INSERT INTO bee_governance_plan_slots
  (owner_node, workspace_id, source_node, source_workspace, version, plan_revision, selected_by, selected_at)
SELECT owner_node, workspace_id, source_node, source_workspace, version, plan_revision, selected_by, selected_at
FROM bee_governance_plan_selection;

CREATE TABLE bee_governance_activation_slots (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  overlay_owner TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK(revision >= 0),
  desired_intent_id TEXT,
  desired_execution_revision INTEGER CHECK(desired_execution_revision IS NULL OR desired_execution_revision >= 1),
  observed_intent_id TEXT,
  observed_execution_revision INTEGER CHECK(observed_execution_revision IS NULL OR observed_execution_revision >= 1),
  observed_artifact_digest TEXT CHECK(observed_artifact_digest IS NULL OR length(observed_artifact_digest) = 64),
  observed_outcome TEXT CHECK(observed_outcome IS NULL OR observed_outcome IN ('applied', 'blocked', 'failed', 'uncertain')),
  updated_at TEXT NOT NULL,
  PRIMARY KEY(owner_node, workspace_id, overlay_owner),
  FOREIGN KEY(owner_node, workspace_id, desired_intent_id)
    REFERENCES bee_governance_activation_intents(owner_node, workspace_id, intent_id),
  FOREIGN KEY(owner_node, workspace_id, observed_intent_id)
    REFERENCES bee_governance_activation_intents(owner_node, workspace_id, intent_id),
  CHECK((desired_intent_id IS NULL) = (desired_execution_revision IS NULL)),
  CHECK((observed_intent_id IS NULL) = (observed_execution_revision IS NULL))
);
INSERT INTO bee_governance_activation_slots
  (owner_node, workspace_id, overlay_owner, revision, desired_intent_id,
   desired_execution_revision, observed_intent_id, observed_execution_revision,
   observed_artifact_digest, observed_outcome, updated_at)
SELECT s.owner_node, s.workspace_id, COALESCE(desired.overlay_owner, observed.overlay_owner),
       s.revision, s.desired_intent_id, s.desired_execution_revision,
       s.observed_intent_id, s.observed_execution_revision,
       s.observed_artifact_digest, s.observed_outcome, s.updated_at
FROM bee_governance_activation_slot s
LEFT JOIN bee_governance_activation_intents desired
  ON desired.owner_node = s.owner_node AND desired.workspace_id = s.workspace_id
 AND desired.intent_id = s.desired_intent_id
LEFT JOIN bee_governance_activation_intents observed
  ON observed.owner_node = s.owner_node AND observed.workspace_id = s.workspace_id
 AND observed.intent_id = s.observed_intent_id
WHERE COALESCE(desired.overlay_owner, observed.overlay_owner) IS NOT NULL;
CREATE INDEX bee_governance_activation_slots_workspace
  ON bee_governance_activation_slots(owner_node, workspace_id, overlay_owner);
]]

-- Migration execution remains part of the activation effect.  The immutable
-- work is stored with the intent; progress and receipts remain mutable, and a
-- separate checksum ledger lets later preflight distinguish an append from a
-- changed or removed migration without trusting package metadata.
local ACTIVATION_MIGRATIONS_SQL = [[
ALTER TABLE bee_governance_activation_intents ADD COLUMN migration_work_bytes BLOB
  CHECK(migration_work_bytes IS NULL OR length(CAST(migration_work_bytes AS BLOB)) BETWEEN 1 AND 1048576);
ALTER TABLE bee_governance_activation_intents ADD COLUMN migration_work_digest TEXT
  CHECK(migration_work_digest IS NULL OR length(migration_work_digest) = 64);
ALTER TABLE bee_governance_activation_execution ADD COLUMN migrations_completed INTEGER NOT NULL DEFAULT 0
  CHECK(migrations_completed IN (0, 1));
ALTER TABLE bee_governance_activation_execution ADD COLUMN migration_receipt_bytes BLOB
  CHECK(migration_receipt_bytes IS NULL OR length(CAST(migration_receipt_bytes AS BLOB)) BETWEEN 1 AND 262144);
ALTER TABLE bee_governance_activation_execution ADD COLUMN migration_receipt_digest TEXT
  CHECK(migration_receipt_digest IS NULL OR length(migration_receipt_digest) = 64);

CREATE TABLE bee_governance_applied_migrations (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  target_db TEXT NOT NULL,
  migration_id TEXT NOT NULL,
  component TEXT NOT NULL,
  ordinal INTEGER NOT NULL CHECK(ordinal >= 1),
  checksum TEXT NOT NULL CHECK(length(checksum) = 64),
  intent_id TEXT NOT NULL,
  applied_at TEXT NOT NULL,
  PRIMARY KEY(owner_node, workspace_id, target_db, migration_id),
  FOREIGN KEY(owner_node, workspace_id, intent_id)
    REFERENCES bee_governance_activation_intents(owner_node, workspace_id, intent_id)
);
CREATE INDEX bee_governance_applied_migrations_component
  ON bee_governance_applied_migrations(owner_node, workspace_id, component, target_db, ordinal);

CREATE TABLE bee_governance_activation_receipts_v7 (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  operation TEXT NOT NULL CHECK(operation IN ('prepare_activation', 'bind_approval', 'begin_consume', 'record_consumption', 'begin_apply', 'record_migrations', 'record_outcome')),
  request_digest TEXT NOT NULL CHECK(length(request_digest) = 64),
  intent_id TEXT NOT NULL,
  result_revision INTEGER NOT NULL CHECK(result_revision >= 1),
  PRIMARY KEY(owner_node, workspace_id, idempotency_key),
  FOREIGN KEY(owner_node, workspace_id, intent_id)
    REFERENCES bee_governance_activation_intents(owner_node, workspace_id, intent_id)
);
INSERT INTO bee_governance_activation_receipts_v7
  SELECT * FROM bee_governance_activation_receipts;
DROP TABLE bee_governance_activation_receipts;
ALTER TABLE bee_governance_activation_receipts_v7 RENAME TO bee_governance_activation_receipts;
]]

-- Application admission is optional for legacy profiles, but when present it
-- is immutable evidence paired with its measured digest.
local ACTIVATION_APPLICATION_ADMISSION_SQL = [[
ALTER TABLE bee_governance_activation_intents ADD COLUMN application_admission_bytes BLOB
  CHECK(application_admission_bytes IS NULL OR length(CAST(application_admission_bytes AS BLOB)) BETWEEN 1 AND 65536);
ALTER TABLE bee_governance_activation_intents ADD COLUMN application_admission_digest TEXT
  CHECK((application_admission_bytes IS NULL) = (application_admission_digest IS NULL))
  CHECK(application_admission_digest IS NULL OR length(application_admission_digest) = 64);
]]

-- Append receipts use the assembled file digest. Existing receipts retain
-- their original operation, key and result revision across this table rebuild.
local WORKSPACE_APPEND_SQL = [[
CREATE TABLE bee_governance_receipts_v9 (
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
);
INSERT INTO bee_governance_receipts_v9 SELECT * FROM bee_governance_receipts;
DROP TABLE bee_governance_receipts;
ALTER TABLE bee_governance_receipts_v9 RENAME TO bee_governance_receipts;
]]
-- A contained upgrade records the exact live grant record used for reuse.
-- It remains distinct from a consumed approval proposal during recovery.
local ACTIVATION_GRANT_REUSE_SQL = [[
ALTER TABLE bee_governance_activation_intents ADD COLUMN grant_predecessor_digest TEXT
  CHECK(grant_predecessor_digest IS NULL OR length(grant_predecessor_digest) = 64);
ALTER TABLE bee_governance_activation_execution ADD COLUMN grant_reuse_digest TEXT
  CHECK(grant_reuse_digest IS NULL OR length(grant_reuse_digest) = 64);
]]


function M.all(): {Migration}
    return {
        {id = 1, name = "governance_workspace_staging", sql = INITIAL, rebuild = false},
        {id = 2, name = "governance_received_plans", sql = PLANS_SQL, rebuild = false},
        {id = 3, name = "governance_plan_approval_proposal", sql = APPROVAL_PROPOSAL_SQL, rebuild = false},
        {id = 4, name = "governance_plan_approval_incarnation", sql = APPROVAL_INCARNATION_SQL, rebuild = false},
        {id = 5, name = "governance_activation_intents", sql = ACTIVATION_SQL, rebuild = false},
        {id = 6, name = "governance_component_slots", sql = COMPONENT_SLOTS_SQL, rebuild = false},
        {id = 7, name = "governance_activation_migrations", sql = ACTIVATION_MIGRATIONS_SQL, rebuild = false},
        {id = 8, name = "governance_activation_application_admission", sql = ACTIVATION_APPLICATION_ADMISSION_SQL, rebuild = false},
        {id = 9, name = "governance_workspace_append", sql = WORKSPACE_APPEND_SQL, rebuild = false},
        {id = 10, name = "governance_activation_grant_reuse", sql = ACTIVATION_GRANT_REUSE_SQL, rebuild = false},
    }
end

return M
