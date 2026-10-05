-- MIT. Immutable schema for the governance-owned, node-local authoring store.
local M = {}

type Migration = {id: integer, name: string, sql: string, rebuild: boolean, historical_sql: {string}?}

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
-- A one-step revert needs the last good generation retained next to the
-- observed pointer, the compensating migration receipt that makes the
-- forward-only schema re-compatible, and a receipt operation of its own.
local ACTIVATION_ROLLBACK_SQL = [[
ALTER TABLE bee_governance_activation_slots ADD COLUMN baseline_intent_id TEXT;
ALTER TABLE bee_governance_activation_slots ADD COLUMN baseline_execution_revision INTEGER
  CHECK(baseline_execution_revision IS NULL OR baseline_execution_revision >= 1);
ALTER TABLE bee_governance_activation_slots ADD COLUMN baseline_artifact_digest TEXT
  CHECK(baseline_artifact_digest IS NULL OR length(baseline_artifact_digest) = 64);
CREATE TABLE bee_governance_activation_reverts (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  overlay_owner TEXT NOT NULL,
  reverted_from_intent_id TEXT NOT NULL,
  target_intent_id TEXT NOT NULL,
  compensation_bytes BLOB NOT NULL CHECK(length(CAST(compensation_bytes AS BLOB)) BETWEEN 1 AND 262144),
  compensation_digest TEXT NOT NULL CHECK(length(compensation_digest) = 64),
  diagnostics TEXT CHECK(diagnostics IS NULL OR length(CAST(diagnostics AS BLOB)) <= 8192),
  created_at TEXT NOT NULL,
  PRIMARY KEY(owner_node, workspace_id, overlay_owner),
  FOREIGN KEY(owner_node, workspace_id, reverted_from_intent_id)
    REFERENCES bee_governance_activation_intents(owner_node, workspace_id, intent_id),
  FOREIGN KEY(owner_node, workspace_id, target_intent_id)
    REFERENCES bee_governance_activation_intents(owner_node, workspace_id, intent_id)
);
CREATE TABLE bee_governance_activation_receipts_v11 (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  operation TEXT NOT NULL CHECK(operation IN ('prepare_activation', 'bind_approval', 'begin_consume', 'record_consumption', 'begin_apply', 'record_migrations', 'record_outcome', 'revert_activation')),
  request_digest TEXT NOT NULL CHECK(length(request_digest) = 64),
  intent_id TEXT NOT NULL,
  result_revision INTEGER NOT NULL CHECK(result_revision >= 1),
  PRIMARY KEY(owner_node, workspace_id, idempotency_key),
  FOREIGN KEY(owner_node, workspace_id, intent_id)
    REFERENCES bee_governance_activation_intents(owner_node, workspace_id, intent_id)
);
INSERT INTO bee_governance_activation_receipts_v11
  SELECT * FROM bee_governance_activation_receipts;
DROP TABLE bee_governance_activation_receipts;
ALTER TABLE bee_governance_activation_receipts_v11 RENAME TO bee_governance_activation_receipts;
]]

-- A contained upgrade records the exact live grant record used for reuse.
-- It remains distinct from a consumed approval proposal during recovery.
local ACTIVATION_GRANT_REUSE_SQL = [[
ALTER TABLE bee_governance_activation_intents ADD COLUMN grant_predecessor_digest TEXT
  CHECK(grant_predecessor_digest IS NULL OR length(grant_predecessor_digest) = 64);
ALTER TABLE bee_governance_activation_execution ADD COLUMN grant_reuse_digest TEXT
  CHECK(grant_reuse_digest IS NULL OR length(grant_reuse_digest) = 64);
]]

-- Every governance store belongs to one state identity. The store-owned
-- migration helper moves owner_node rows from the recorded native alias in a
-- single transaction and records completion here.
local NODE_IDENTITY_MIGRATION_SQL = [[
CREATE TABLE bee_governance_node_identity_migrations (
  source_node TEXT NOT NULL,
  destination_node TEXT NOT NULL,
  migrated_at TEXT NOT NULL,
  PRIMARY KEY(source_node, destination_node),
  CHECK(source_node <> destination_node)
);
]]

-- Keep the identity inputs used by an existing plan digest when its owner
-- partition is migrated. The approval remains bound to that historical digest.
local PLAN_IDENTITY_DIGEST_SQL = [[
ALTER TABLE bee_governance_plans ADD COLUMN identity_digest_owner_node TEXT NOT NULL DEFAULT '';
ALTER TABLE bee_governance_plans ADD COLUMN identity_digest_source_node TEXT NOT NULL DEFAULT '';
UPDATE bee_governance_plans
  SET identity_digest_owner_node = owner_node, identity_digest_source_node = source_node;
]]


-- A lease is a person-granted, bounded ceiling over capability grants: a
-- future non-empty capability diff that stays inside it applies without a
-- second decision. Its authority traces to one approval (source_approval_*);
-- expiry and use-count are computed at read time from expires_at/max_applies/
-- applies_used, so the stored state only ever tracks whether a person has
-- explicitly revoked it. A use is reserved when it authorizes an intent,
-- admitted when the effect starts, and fenced when a revocation lands first.
local LEASES_SQL = [[
CREATE TABLE bee_governance_leases (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  lease_id TEXT NOT NULL,
  target TEXT NOT NULL,
  envelope_bytes BLOB NOT NULL CHECK(length(CAST(envelope_bytes AS BLOB)) BETWEEN 1 AND 65536),
  envelope_digest TEXT NOT NULL CHECK(length(envelope_digest) = 64),
  source_approval_id TEXT NOT NULL,
  source_approval_proposal_digest TEXT NOT NULL CHECK(length(source_approval_proposal_digest) = 64),
  source_approval_owner_incarnation INTEGER NOT NULL CHECK(source_approval_owner_incarnation >= 1),
  granted_by TEXT NOT NULL,
  created_at TEXT NOT NULL,
  expires_at TEXT,
  max_applies INTEGER CHECK(max_applies IS NULL OR max_applies >= 1),
  applies_used INTEGER NOT NULL DEFAULT 0 CHECK(applies_used >= 0),
  revision INTEGER NOT NULL CHECK(revision >= 1),
  state TEXT NOT NULL CHECK(state IN ('active', 'revoked')),
  revoked_by TEXT,
  revoked_at TEXT,
  PRIMARY KEY(owner_node, workspace_id, lease_id),
  UNIQUE(owner_node, workspace_id, source_approval_id),
  CHECK(expires_at IS NOT NULL OR max_applies IS NOT NULL)
);
CREATE INDEX bee_governance_leases_target ON bee_governance_leases (owner_node, workspace_id, target, state);
CREATE TABLE bee_governance_lease_uses (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  lease_id TEXT NOT NULL,
  intent_id TEXT NOT NULL,
  approval_id TEXT NOT NULL,
  approval_proposal_digest TEXT NOT NULL CHECK(length(approval_proposal_digest) = 64),
  proposal_snapshot_bytes BLOB NOT NULL CHECK(length(CAST(proposal_snapshot_bytes AS BLOB)) BETWEEN 1 AND 65536),
  proposal_snapshot_digest TEXT NOT NULL CHECK(length(proposal_snapshot_digest) = 64),
  state TEXT NOT NULL CHECK(state IN ('reserved', 'admitted', 'fenced')),
  applied_at TEXT NOT NULL,
  admitted_at TEXT,
  PRIMARY KEY(owner_node, workspace_id, lease_id, intent_id),
  UNIQUE(owner_node, workspace_id, intent_id),
  FOREIGN KEY(owner_node, workspace_id, lease_id)
    REFERENCES bee_governance_leases(owner_node, workspace_id, lease_id)
);
CREATE TABLE bee_governance_lease_receipts (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  operation TEXT NOT NULL CHECK(operation IN ('grant', 'use', 'revoke')),
  request_digest TEXT NOT NULL CHECK(length(request_digest) = 64),
  lease_id TEXT NOT NULL,
  result_revision INTEGER NOT NULL CHECK(result_revision >= 1),
  PRIMARY KEY(owner_node, workspace_id, idempotency_key)
);
]]

-- A revocation's answer (which reserved uses it fenced and which effects had
-- already started) is kept with its receipt so a lost reply can be replayed.
local LEASE_RECEIPT_RESULT_SQL = [[
ALTER TABLE bee_governance_lease_receipts ADD COLUMN result_json TEXT;
]]

local ORIGINAL_SQL_14 = [[
CREATE TABLE bee_governance_leases (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  lease_id TEXT NOT NULL,
  target TEXT NOT NULL,
  envelope_bytes BLOB NOT NULL CHECK(length(CAST(envelope_bytes AS BLOB)) BETWEEN 1 AND 65536),
  envelope_digest TEXT NOT NULL CHECK(length(envelope_digest) = 64),
  source_approval_id TEXT NOT NULL,
  source_approval_proposal_digest TEXT NOT NULL CHECK(length(source_approval_proposal_digest) = 64),
  source_approval_owner_incarnation INTEGER NOT NULL CHECK(source_approval_owner_incarnation >= 1),
  granted_by TEXT NOT NULL,
  created_at TEXT NOT NULL,
  expires_at TEXT,
  max_applies INTEGER CHECK(max_applies IS NULL OR max_applies >= 1),
  applies_used INTEGER NOT NULL DEFAULT 0 CHECK(applies_used >= 0),
  revision INTEGER NOT NULL CHECK(revision >= 1),
  state TEXT NOT NULL CHECK(state IN ('active', 'revoked')),
  revoked_by TEXT,
  revoked_at TEXT,
  PRIMARY KEY(owner_node, workspace_id, lease_id),
  UNIQUE(owner_node, workspace_id, source_approval_id),
  CHECK(expires_at IS NOT NULL OR max_applies IS NOT NULL)
);
CREATE INDEX bee_governance_leases_target ON bee_governance_leases (owner_node, workspace_id, target, state);
CREATE TABLE bee_governance_lease_uses (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  lease_id TEXT NOT NULL,
  intent_id TEXT NOT NULL,
  proposal_snapshot_bytes BLOB NOT NULL CHECK(length(CAST(proposal_snapshot_bytes AS BLOB)) BETWEEN 1 AND 65536),
  proposal_snapshot_digest TEXT NOT NULL CHECK(length(proposal_snapshot_digest) = 64),
  applied_at TEXT NOT NULL,
  PRIMARY KEY(owner_node, workspace_id, lease_id, intent_id),
  FOREIGN KEY(owner_node, workspace_id, lease_id)
    REFERENCES bee_governance_leases(owner_node, workspace_id, lease_id)
);
CREATE TABLE bee_governance_lease_receipts (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  operation TEXT NOT NULL CHECK(operation IN ('grant', 'use', 'revoke')),
  request_digest TEXT NOT NULL CHECK(length(request_digest) = 64),
  lease_id TEXT NOT NULL,
  result_revision INTEGER NOT NULL CHECK(result_revision >= 1),
  PRIMARY KEY(owner_node, workspace_id, idempotency_key)
);
]]

local LEASE_USES_REPAIR_SQL = [[
CREATE TABLE bee_governance_lease_uses_next (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  lease_id TEXT NOT NULL,
  intent_id TEXT NOT NULL,
  approval_id TEXT NOT NULL,
  approval_proposal_digest TEXT NOT NULL CHECK(length(approval_proposal_digest) = 64),
  proposal_snapshot_bytes BLOB NOT NULL CHECK(length(CAST(proposal_snapshot_bytes AS BLOB)) BETWEEN 1 AND 65536),
  proposal_snapshot_digest TEXT NOT NULL CHECK(length(proposal_snapshot_digest) = 64),
  state TEXT NOT NULL CHECK(state IN ('reserved', 'admitted', 'fenced')),
  applied_at TEXT NOT NULL,
  admitted_at TEXT,
  PRIMARY KEY(owner_node, workspace_id, lease_id, intent_id),
  UNIQUE(owner_node, workspace_id, intent_id),
  FOREIGN KEY(owner_node, workspace_id, lease_id)
    REFERENCES bee_governance_leases(owner_node, workspace_id, lease_id)
);
INSERT INTO bee_governance_lease_uses_next
    (owner_node, workspace_id, lease_id, intent_id, approval_id, approval_proposal_digest,
     proposal_snapshot_bytes, proposal_snapshot_digest, state, applied_at, admitted_at)
SELECT owner_node, workspace_id, lease_id, intent_id,
    CASE WHEN EXISTS (SELECT 1 FROM pragma_table_info('bee_governance_lease_uses') WHERE name = 'approval_id')
         THEN "approval_id" ELSE (SELECT source_approval_id FROM bee_governance_leases lease
          WHERE lease.owner_node = uses.owner_node AND lease.workspace_id = uses.workspace_id AND lease.lease_id = uses.lease_id) END,
    CASE WHEN EXISTS (SELECT 1 FROM pragma_table_info('bee_governance_lease_uses') WHERE name = 'approval_proposal_digest')
         THEN "approval_proposal_digest" ELSE (SELECT source_approval_proposal_digest FROM bee_governance_leases lease
          WHERE lease.owner_node = uses.owner_node AND lease.workspace_id = uses.workspace_id AND lease.lease_id = uses.lease_id) END,
    proposal_snapshot_bytes, proposal_snapshot_digest,
    CASE WHEN EXISTS (SELECT 1 FROM pragma_table_info('bee_governance_lease_uses') WHERE name = 'state')
         THEN "state" ELSE 'admitted' END,
    applied_at,
    CASE WHEN EXISTS (SELECT 1 FROM pragma_table_info('bee_governance_lease_uses') WHERE name = 'admitted_at')
         THEN "admitted_at" ELSE applied_at END
FROM bee_governance_lease_uses uses;
DROP TABLE bee_governance_lease_uses;
ALTER TABLE bee_governance_lease_uses_next RENAME TO bee_governance_lease_uses;
]]

local APPLICATION_ADMISSION_GENERATION_SQL = [[
ALTER TABLE bee_governance_activation_intents ADD COLUMN application_admission_generation TEXT NOT NULL DEFAULT 'current' CHECK(application_admission_generation IN ('current', 'prior'));
UPDATE bee_governance_activation_intents
SET application_admission_generation = coalesce(json_extract(application_admission_bytes, '$.identity_generation'),
  CASE WHEN substr(overlay_owner, 1, length('bee.governance.workspace_applications:')) = 'bee.governance.workspace_applications:' THEN 'prior' ELSE 'current' END)
WHERE application_admission_bytes IS NOT NULL;
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
        {id = 11, name = "governance_activation_rollback", sql = ACTIVATION_ROLLBACK_SQL, rebuild = false},
        {id = 12, name = "governance_node_identity_migration", sql = NODE_IDENTITY_MIGRATION_SQL, rebuild = false},
        {id = 13, name = "governance_plan_identity_digest", sql = PLAN_IDENTITY_DIGEST_SQL, rebuild = false},
        {id = 14, name = "governance_capability_leases", historical_sql = {ORIGINAL_SQL_14}, sql = LEASES_SQL, rebuild = false},
        {id = 15, name = "governance_lease_receipt_result", sql = LEASE_RECEIPT_RESULT_SQL, rebuild = false},
        {id = 16, name = "governance_lease_use_admission_repair", sql = LEASE_USES_REPAIR_SQL, rebuild = true},
        {id = 17, name = "governance_application_admission_generation", sql = APPLICATION_ADMISSION_GENERATION_SQL, rebuild = false},
    }
end

return M
