-- MIT. The destination activation ledger. An intent is immutable installation
-- evidence; approval and execution progress live in a separate row, and each
-- overlay owner's slot keeps the authorized desired intent apart from the
-- observed one and the retained baseline a revert restores. Applied
-- migrations are recorded per target database so preflight can tell an
-- appended migration from a changed or removed one.
local STATEMENTS = {
    [[CREATE TABLE bee_governance_activation_intents (
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
  migration_work_bytes BLOB CHECK(migration_work_bytes IS NULL OR length(CAST(migration_work_bytes AS BLOB)) BETWEEN 1 AND 1048576),
  migration_work_digest TEXT CHECK(migration_work_digest IS NULL OR length(migration_work_digest) = 64),
  grant_predecessor_digest TEXT CHECK(grant_predecessor_digest IS NULL OR length(grant_predecessor_digest) = 64),
  authorization_digest TEXT NOT NULL CHECK(length(authorization_digest) = 64),
  effect_key TEXT NOT NULL CHECK(length(effect_key) = 64),
  created_at TEXT NOT NULL,
  PRIMARY KEY(owner_node, workspace_id, intent_id),
  UNIQUE(owner_node, workspace_id, effect_key)
)]],
    [[CREATE TABLE bee_governance_activation_execution (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  intent_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK(revision >= 1),
  phase TEXT NOT NULL CHECK(phase IN ('prepared', 'approval_bound', 'consuming', 'authorized', 'applying', 'settled')),
  approval_id TEXT,
  approval_proposal_digest TEXT CHECK(approval_proposal_digest IS NULL OR length(approval_proposal_digest) = 64),
  approval_owner_incarnation INTEGER CHECK(approval_owner_incarnation IS NULL OR approval_owner_incarnation >= 1),
  grant_reuse_digest TEXT CHECK(grant_reuse_digest IS NULL OR length(grant_reuse_digest) = 64),
  consumed_consumer_id TEXT,
  consumed_proposal_digest TEXT CHECK(consumed_proposal_digest IS NULL OR length(consumed_proposal_digest) = 64),
  consumed_effect_key TEXT,
  outcome TEXT CHECK(outcome IS NULL OR outcome IN ('applied', 'blocked', 'failed', 'uncertain')),
  diagnostics TEXT CHECK(diagnostics IS NULL OR length(CAST(diagnostics AS BLOB)) <= 8192),
  migrations_completed INTEGER NOT NULL DEFAULT 0 CHECK(migrations_completed IN (0, 1)),
  migration_receipt_bytes BLOB CHECK(migration_receipt_bytes IS NULL OR length(CAST(migration_receipt_bytes AS BLOB)) BETWEEN 1 AND 262144),
  migration_receipt_digest TEXT CHECK(migration_receipt_digest IS NULL OR length(migration_receipt_digest) = 64),
  updated_at TEXT NOT NULL,
  PRIMARY KEY(owner_node, workspace_id, intent_id),
  FOREIGN KEY(owner_node, workspace_id, intent_id) REFERENCES bee_governance_activation_intents(owner_node, workspace_id, intent_id),
  CHECK((((phase IN ('approval_bound', 'consuming', 'authorized', 'applying', 'settled')) AND approval_id IS NOT NULL) OR ((phase = 'prepared') AND approval_id IS NULL))),
  CHECK((((phase IN ('authorized', 'applying', 'settled')) AND consumed_consumer_id IS NOT NULL AND consumed_proposal_digest IS NOT NULL AND consumed_effect_key IS NOT NULL) OR ((phase IN ('prepared', 'approval_bound', 'consuming')) AND consumed_consumer_id IS NULL AND consumed_proposal_digest IS NULL AND consumed_effect_key IS NULL))),
  CHECK(((phase = 'settled') AND outcome IS NOT NULL) OR ((phase <> 'settled') AND outcome IS NULL))
)]],
    [[CREATE TABLE bee_governance_activation_slots (
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
  baseline_intent_id TEXT,
  baseline_execution_revision INTEGER CHECK(baseline_execution_revision IS NULL OR baseline_execution_revision >= 1),
  baseline_artifact_digest TEXT CHECK(baseline_artifact_digest IS NULL OR length(baseline_artifact_digest) = 64),
  updated_at TEXT NOT NULL,
  PRIMARY KEY(owner_node, workspace_id, overlay_owner),
  FOREIGN KEY(owner_node, workspace_id, desired_intent_id)
    REFERENCES bee_governance_activation_intents(owner_node, workspace_id, intent_id),
  FOREIGN KEY(owner_node, workspace_id, observed_intent_id)
    REFERENCES bee_governance_activation_intents(owner_node, workspace_id, intent_id),
  CHECK((desired_intent_id IS NULL) = (desired_execution_revision IS NULL)),
  CHECK((observed_intent_id IS NULL) = (observed_execution_revision IS NULL))
)]],
    [[CREATE TABLE bee_governance_activation_receipts (
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
)]],
    [[CREATE TABLE bee_governance_applied_migrations (
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
)]],
    [[CREATE TABLE bee_governance_activation_reverts (
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
)]],
    "CREATE INDEX bee_governance_activation_phase ON bee_governance_activation_execution(owner_node, workspace_id, phase)",
    "CREATE INDEX bee_governance_activation_slots_workspace ON bee_governance_activation_slots(owner_node, workspace_id, overlay_owner)",
    "CREATE INDEX bee_governance_applied_migrations_component ON bee_governance_applied_migrations(owner_node, workspace_id, component, target_db, ordinal)",
}

return require("migration").define(function()
    migration("Create governance activation ledger", function()
        database("sqlite", function()
            up(function(db)
                for _, statement in ipairs(STATEMENTS) do
                    local _, err = db:execute(statement)
                    if err then error(err) end
                end
            end)
            down(function(db)
                for _, name in ipairs({"bee_governance_activation_reverts", "bee_governance_applied_migrations",
                    "bee_governance_activation_receipts", "bee_governance_activation_slots",
                    "bee_governance_activation_execution", "bee_governance_activation_intents"}) do
                    local _, err = db:execute("DROP TABLE IF EXISTS " .. name)
                    if err then error(err) end
                end
            end)
        end)
    end)
end)
