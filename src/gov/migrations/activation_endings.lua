-- MIT. Let an activation settle as its approval request ended without approval:
-- denied, expired or withdrawn, never having been consumed. The execution
-- table is rebuilt with its rows; foreign keys are checked when the migration
-- commits.
local STATEMENTS = {
    [[PRAGMA defer_foreign_keys = ON]],
    [[CREATE TABLE bee_governance_activation_execution_next ( owner_node TEXT NOT NULL, workspace_id TEXT NOT NULL, intent_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision >= 1), phase TEXT NOT NULL CHECK(phase IN ('prepared', 'approval_bound', 'consuming', 'authorized', 'applying', 'settled')), approval_id TEXT, approval_proposal_digest TEXT CHECK(approval_proposal_digest IS NULL OR length(approval_proposal_digest) = 64), approval_owner_incarnation INTEGER CHECK(approval_owner_incarnation IS NULL OR approval_owner_incarnation >= 1), consumed_consumer_id TEXT, consumed_proposal_digest TEXT CHECK(consumed_proposal_digest IS NULL OR length(consumed_proposal_digest) = 64), consumed_effect_key TEXT, outcome TEXT CHECK(outcome IS NULL OR outcome IN ('applied', 'blocked', 'failed', 'uncertain', 'denied', 'expired', 'withdrawn')), diagnostics TEXT CHECK(diagnostics IS NULL OR length(CAST(diagnostics AS BLOB)) <= 8192), updated_at TEXT NOT NULL, migrations_completed INTEGER NOT NULL DEFAULT 0 CHECK(migrations_completed IN (0, 1)), migration_receipt_bytes BLOB CHECK(migration_receipt_bytes IS NULL OR length(CAST(migration_receipt_bytes AS BLOB)) BETWEEN 1 AND 262144), migration_receipt_digest TEXT CHECK(migration_receipt_digest IS NULL OR length(migration_receipt_digest) = 64), grant_reuse_digest TEXT CHECK(grant_reuse_digest IS NULL OR length(grant_reuse_digest) = 64), PRIMARY KEY(owner_node, workspace_id, intent_id), FOREIGN KEY(owner_node, workspace_id, intent_id) REFERENCES bee_governance_activation_intents(owner_node, workspace_id, intent_id), CHECK((((phase IN ('approval_bound', 'consuming', 'authorized', 'applying', 'settled')) AND approval_id IS NOT NULL) OR ((phase = 'prepared') AND approval_id IS NULL))), CHECK((((phase IN ('authorized', 'applying') OR (phase = 'settled' AND outcome NOT IN ('denied', 'expired', 'withdrawn'))) AND consumed_consumer_id IS NOT NULL AND consumed_proposal_digest IS NOT NULL AND consumed_effect_key IS NOT NULL) OR ((phase IN ('prepared', 'approval_bound', 'consuming') OR (phase = 'settled' AND outcome IN ('denied', 'expired', 'withdrawn'))) AND consumed_consumer_id IS NULL AND consumed_proposal_digest IS NULL AND consumed_effect_key IS NULL))), CHECK(((phase = 'settled') AND outcome IS NOT NULL) OR ((phase <> 'settled') AND outcome IS NULL)) )]],
    [[INSERT INTO bee_governance_activation_execution_next (owner_node, workspace_id, intent_id, revision, phase, approval_id, approval_proposal_digest, approval_owner_incarnation, consumed_consumer_id, consumed_proposal_digest, consumed_effect_key, outcome, diagnostics, updated_at, migrations_completed, migration_receipt_bytes, migration_receipt_digest, grant_reuse_digest) SELECT owner_node, workspace_id, intent_id, revision, phase, approval_id, approval_proposal_digest, approval_owner_incarnation, consumed_consumer_id, consumed_proposal_digest, consumed_effect_key, outcome, diagnostics, updated_at, migrations_completed, migration_receipt_bytes, migration_receipt_digest, grant_reuse_digest FROM bee_governance_activation_execution]],
    [[DROP TABLE bee_governance_activation_execution]],
    [[ALTER TABLE bee_governance_activation_execution_next RENAME TO bee_governance_activation_execution]],
    [[CREATE INDEX IF NOT EXISTS bee_governance_activation_phase ON bee_governance_activation_execution(owner_node, workspace_id, phase)]],
}

return require("migration").define(function()
    migration("Settle an activation whose approval request ended without approval", function()
        database("sqlite", function()
            up(function(db)
                for _, statement in ipairs(STATEMENTS) do
                    local _, err = db:execute(statement)
                    if err then error(err) end
                end
            end)
        end)
    end)
end)
