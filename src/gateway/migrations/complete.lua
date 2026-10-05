-- MIT. Complete the gateway store to its full schema: binding epochs and expiry, access grants and the listener; bindings from before carry no epoch and are dropped with their credentials, hooks and surfaces.
-- A table whose definition changes is renamed aside, created again and given
-- its rows back; foreign keys are checked when the migration commits.
local STATEMENTS = {
    [[PRAGMA defer_foreign_keys = ON]],
    [[DROP INDEX bee_gateway_bindings_attempt]],
    [[DROP INDEX bee_gateway_hooks_occurrence]],
    [[DROP INDEX bee_gateway_hooks_status]],
    [[ALTER TABLE bee_gateway_bindings RENAME TO bee_gateway_bindings_prev]],
    [[ALTER TABLE bee_gateway_credentials RENAME TO bee_gateway_credentials_prev]],
    [[ALTER TABLE bee_gateway_hooks RENAME TO bee_gateway_hooks_prev]],
    [[ALTER TABLE bee_gateway_surfaces RENAME TO bee_gateway_surfaces_prev]],
    [[CREATE TABLE "bee_gateway_bindings" ( binding_id TEXT PRIMARY KEY, subject TEXT NOT NULL, action_id TEXT NOT NULL, attempt_id TEXT NOT NULL, thread_id TEXT NOT NULL, owner_incarnation INTEGER NOT NULL CHECK (owner_incarnation > 0), carrier_epoch INTEGER NOT NULL CHECK (carrier_epoch >= 0), tools_json TEXT NOT NULL, epoch INTEGER NOT NULL CHECK (epoch >= 0), credential_generation INTEGER NOT NULL CHECK (credential_generation >= 0), expires_at TEXT NOT NULL, revoked_at TEXT, idempotency_key TEXT, request_digest TEXT, created_at TEXT NOT NULL , materialization_key_hash TEXT, materialization_expires_at TEXT, hooks_json TEXT NOT NULL DEFAULT '[]', sealed_at TEXT, policy_ref TEXT, workspace_id TEXT, origin_view_json TEXT, workspace_name TEXT)]],
    [[CREATE TABLE "bee_gateway_credentials" ( credential_id TEXT PRIMARY KEY, binding_id TEXT NOT NULL REFERENCES bee_gateway_bindings(binding_id), generation INTEGER NOT NULL CHECK (generation > 0), kind TEXT NOT NULL CHECK (kind IN ('tool', 'hook')), token_hash TEXT NOT NULL UNIQUE, runner TEXT NOT NULL, materialized_at TEXT NOT NULL, revoked_at TEXT, presented_count INTEGER NOT NULL DEFAULT 0, last_presented_at TEXT, UNIQUE (binding_id, generation, kind) )]],
    [[CREATE TABLE "bee_gateway_hooks" ( event_id TEXT PRIMARY KEY, binding_id TEXT NOT NULL REFERENCES bee_gateway_bindings(binding_id), attempt_id TEXT NOT NULL, action_id TEXT NOT NULL, carrier_epoch INTEGER NOT NULL, event TEXT NOT NULL, occurrence TEXT NOT NULL, ambiguous INTEGER NOT NULL CHECK (ambiguous IN (0, 1)), digest TEXT NOT NULL, fields_json TEXT NOT NULL, provenance TEXT NOT NULL, status TEXT NOT NULL CHECK (status IN ('queued', 'committed', 'rejected')), claimed_epoch INTEGER NOT NULL DEFAULT 0, claimed_at TEXT, rejected_reason TEXT, sequence INTEGER NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL )]],
    [[CREATE TABLE "bee_gateway_surfaces" ( binding_id TEXT PRIMARY KEY REFERENCES bee_gateway_bindings(binding_id), surface_json TEXT NOT NULL CHECK(length(CAST(surface_json AS BLOB)) BETWEEN 1 AND 131072), active_json TEXT NOT NULL CHECK(length(CAST(active_json AS BLOB)) BETWEEN 1 AND 8192), context_json TEXT NOT NULL CHECK(length(CAST(context_json AS BLOB)) BETWEEN 1 AND 16384), revision INTEGER NOT NULL CHECK(revision BETWEEN 1 AND 9007199254740991) )]],
    [[CREATE TABLE bee_gateway_listener ( singleton INTEGER PRIMARY KEY CHECK (singleton = 1), epoch INTEGER NOT NULL CHECK (epoch >= 0), address TEXT NOT NULL, drained INTEGER NOT NULL CHECK (drained IN (0, 1)), opened_at TEXT NOT NULL , drain_deadline_at TEXT, secret TEXT NOT NULL DEFAULT '', native_key TEXT)]],
    [[CREATE TABLE bee_gateway_access_grants ( binding_id TEXT NOT NULL REFERENCES bee_gateway_bindings(binding_id), approval_id TEXT NOT NULL, proposal_digest TEXT NOT NULL CHECK(length(proposal_digest) = 64), traits_json TEXT NOT NULL CHECK(length(CAST(traits_json AS BLOB)) BETWEEN 1 AND 8192), PRIMARY KEY(binding_id, approval_id) )]],
    [[DROP TABLE bee_gateway_surfaces_prev]],
    [[DROP TABLE bee_gateway_hooks_prev]],
    [[DROP TABLE bee_gateway_credentials_prev]],
    [[DROP TABLE bee_gateway_bindings_prev]],
    [[CREATE UNIQUE INDEX bee_gateway_bindings_replay ON bee_gateway_bindings(subject, idempotency_key) WHERE idempotency_key IS NOT NULL]],
    [[CREATE INDEX bee_gateway_bindings_attempt ON bee_gateway_bindings(attempt_id, carrier_epoch)]],
    [[CREATE INDEX bee_gateway_bindings_workspace_live ON bee_gateway_bindings(workspace_id, created_at) WHERE revoked_at IS NULL AND workspace_id IS NOT NULL]],
    [[CREATE INDEX bee_gateway_bindings_workspace_name ON bee_gateway_bindings(workspace_id, workspace_name) WHERE revoked_at IS NULL AND workspace_id IS NOT NULL]],
    [[CREATE INDEX bee_gateway_hooks_occurrence ON bee_gateway_hooks(binding_id, event, occurrence)]],
    [[CREATE INDEX bee_gateway_hooks_status ON bee_gateway_hooks(binding_id, status, sequence)]],
}


return require("migration").define(function()
    migration("Complete the gateway store to its full schema: binding epochs and expiry, access grants and the listener; bindings from before carry no epoch and are dropped with their credentials, hooks and surfaces", function()
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
