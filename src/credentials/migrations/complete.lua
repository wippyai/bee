-- MIT. Complete the credential store to its full schema: definitions and projections take their full definitions.
-- A table whose definition changes is renamed aside, created again and given
-- its rows back; foreign keys are checked when the migration commits.
local STATEMENTS = {
    [[PRAGMA defer_foreign_keys = ON]],
    [[DROP INDEX bee_credential_projections_attempt]],
    [[ALTER TABLE bee_credential_generations RENAME TO bee_credential_generations_prev]],
    [[ALTER TABLE bee_credential_projections RENAME TO bee_credential_projections_prev]],
    [[ALTER TABLE bee_credential_definitions RENAME TO bee_credential_definitions_prev]],
    [[CREATE TABLE bee_credential_generations ( projection_id TEXT NOT NULL REFERENCES bee_credential_projections (projection_id), generation_key TEXT NOT NULL, generation INTEGER NOT NULL CHECK (generation > 0), materializer_actor TEXT NOT NULL, created_at TEXT NOT NULL, PRIMARY KEY (projection_id, generation_key) )]],
    [[CREATE TABLE "bee_credential_projections" ( projection_id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, name TEXT NOT NULL, definition_id TEXT NOT NULL, definition_revision INTEGER NOT NULL CHECK (definition_revision > 0), issuer_owner TEXT NOT NULL, issuer_incarnation INTEGER NOT NULL CHECK (issuer_incarnation > 0), subject TEXT NOT NULL, audience TEXT NOT NULL, attempt_id TEXT NOT NULL, profile_id TEXT NOT NULL, profile_digest TEXT NOT NULL, binding_digest TEXT NOT NULL, launch_policy_digest TEXT NOT NULL, provider TEXT NOT NULL, projection_kind TEXT NOT NULL, destination TEXT NOT NULL, materializer TEXT NOT NULL, idempotency_key TEXT NOT NULL, materialization_generation INTEGER NOT NULL DEFAULT 0 CHECK (materialization_generation >= 0), expires_at TEXT NOT NULL, authorization_epoch INTEGER NOT NULL CHECK (authorization_epoch >= 0), revoked_at TEXT, created_at TEXT NOT NULL, format_json TEXT NOT NULL DEFAULT '', UNIQUE (subject, idempotency_key) )]],
    [[CREATE TABLE "bee_credential_definitions" ( workspace_id TEXT NOT NULL, name TEXT NOT NULL, definition_id TEXT NOT NULL UNIQUE, revision INTEGER NOT NULL CHECK (revision > 0), provider TEXT NOT NULL CHECK (length(provider) BETWEEN 1 AND 160), source_kind TEXT NOT NULL CHECK (source_kind IN ('env_variable', 'fs_directory')), source_ref TEXT NOT NULL, projection_kind TEXT NOT NULL CHECK (projection_kind IN ('environment', 'file')), destination TEXT NOT NULL, digest TEXT NOT NULL, owner_node TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, optional INTEGER NOT NULL DEFAULT 0 CHECK (optional IN (0,1)), format_json TEXT NOT NULL DEFAULT '', PRIMARY KEY (workspace_id, name) )]],
    [[INSERT INTO bee_credential_projections (projection_id, workspace_id, name, definition_id, definition_revision, issuer_owner, issuer_incarnation, subject, audience, attempt_id, profile_id, profile_digest, binding_digest, launch_policy_digest, provider, projection_kind, destination, materializer, idempotency_key, materialization_generation, expires_at, authorization_epoch, revoked_at, created_at, format_json) SELECT projection_id, workspace_id, name, definition_id, definition_revision, issuer_owner, issuer_incarnation, subject, audience, attempt_id, profile_id, profile_digest, binding_digest, launch_policy_digest, provider, projection_kind, destination, materializer, idempotency_key, materialization_generation, expires_at, authorization_epoch, revoked_at, created_at, format_json FROM bee_credential_projections_prev]],
    [[INSERT INTO bee_credential_definitions (workspace_id, name, definition_id, revision, provider, source_kind, source_ref, projection_kind, destination, digest, owner_node, created_at, updated_at, optional, format_json) SELECT workspace_id, name, definition_id, revision, provider, source_kind, source_ref, projection_kind, destination, digest, owner_node, created_at, updated_at, optional, format_json FROM bee_credential_definitions_prev]],
    [[INSERT INTO bee_credential_generations (projection_id, generation_key, generation, materializer_actor, created_at) SELECT projection_id, generation_key, generation, materializer_actor, created_at FROM bee_credential_generations_prev]],
    [[DROP TABLE bee_credential_generations_prev]],
    [[DROP TABLE bee_credential_definitions_prev]],
    [[DROP TABLE bee_credential_projections_prev]],
    [[CREATE INDEX bee_credential_projections_attempt ON bee_credential_projections (attempt_id)]],
}


return require("migration").define(function()
    migration("Complete the credential store to its full schema: definitions and projections take their full definitions", function()
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
