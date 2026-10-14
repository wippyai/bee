-- MIT. Let the activation receipts record a person's removal of an application.
-- The receipt table is rebuilt with its rows; foreign keys are checked when the
-- migration commits.
local STATEMENTS = {
    [[PRAGMA defer_foreign_keys = ON]],
    [[CREATE TABLE bee_governance_activation_receipts_next ( owner_node TEXT NOT NULL, workspace_id TEXT NOT NULL, idempotency_key TEXT NOT NULL, actor_id TEXT NOT NULL, operation TEXT NOT NULL CHECK(operation IN ('prepare_activation', 'bind_approval', 'begin_consume', 'record_consumption', 'begin_apply', 'record_migrations', 'record_outcome', 'revert_activation', 'remove_activation')), request_digest TEXT NOT NULL CHECK(length(request_digest) = 64), intent_id TEXT NOT NULL, result_revision INTEGER NOT NULL CHECK(result_revision >= 1), PRIMARY KEY(owner_node, workspace_id, idempotency_key), FOREIGN KEY(owner_node, workspace_id, intent_id) REFERENCES bee_governance_activation_intents(owner_node, workspace_id, intent_id) )]],
    [[INSERT INTO bee_governance_activation_receipts_next (owner_node, workspace_id, idempotency_key, actor_id, operation, request_digest, intent_id, result_revision) SELECT owner_node, workspace_id, idempotency_key, actor_id, operation, request_digest, intent_id, result_revision FROM bee_governance_activation_receipts]],
    [[DROP TABLE bee_governance_activation_receipts]],
    [[ALTER TABLE bee_governance_activation_receipts_next RENAME TO bee_governance_activation_receipts]],
}

return require("migration").define(function()
    migration("Record a person's removal of an application in the activation receipts", function()
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
