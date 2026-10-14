-- MIT. Credential definitions, workspace authorization epochs, projections
-- and consumed materialization generations. No secret bytes are stored:
-- definitions hold source references, projections hold bindings.
local STATEMENTS = {
    [[CREATE TABLE bee_credential_definitions (
  workspace_id TEXT NOT NULL,
  name TEXT NOT NULL,
  definition_id TEXT NOT NULL UNIQUE,
  revision INTEGER NOT NULL CHECK (revision > 0),
  provider TEXT NOT NULL CHECK (length(provider) BETWEEN 1 AND 160),
  source_kind TEXT NOT NULL CHECK (source_kind IN ('env_variable', 'fs_directory')),
  source_ref TEXT NOT NULL,
  projection_kind TEXT NOT NULL CHECK (projection_kind IN ('environment', 'file')),
  destination TEXT NOT NULL,
  optional INTEGER NOT NULL DEFAULT 0 CHECK (optional IN (0, 1)),
  digest TEXT NOT NULL,
  format_json TEXT NOT NULL,
  owner_node TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (workspace_id, name)
)]],
    [[CREATE TABLE bee_credential_epochs (
  workspace_id TEXT PRIMARY KEY,
  epoch INTEGER NOT NULL CHECK (epoch >= 0)
)]],
    [[CREATE TABLE bee_credential_projections (
  projection_id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  name TEXT NOT NULL,
  definition_id TEXT NOT NULL,
  definition_revision INTEGER NOT NULL CHECK (definition_revision > 0),
  issuer_owner TEXT NOT NULL,
  issuer_incarnation INTEGER NOT NULL CHECK (issuer_incarnation > 0),
  subject TEXT NOT NULL,
  audience TEXT NOT NULL,
  attempt_id TEXT NOT NULL,
  profile_id TEXT NOT NULL,
  profile_digest TEXT NOT NULL,
  binding_digest TEXT NOT NULL,
  launch_policy_digest TEXT NOT NULL,
  provider TEXT NOT NULL,
  projection_kind TEXT NOT NULL,
  destination TEXT NOT NULL,
  format_json TEXT NOT NULL,
  materializer TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  materialization_generation INTEGER NOT NULL DEFAULT 0 CHECK (materialization_generation >= 0),
  expires_at TEXT NOT NULL,
  authorization_epoch INTEGER NOT NULL CHECK (authorization_epoch >= 0),
  revoked_at TEXT,
  created_at TEXT NOT NULL,
  UNIQUE (subject, idempotency_key)
)]],
    [[CREATE INDEX bee_credential_projections_attempt ON bee_credential_projections (attempt_id)]],
    [[CREATE TABLE bee_credential_generations (
  projection_id TEXT NOT NULL REFERENCES bee_credential_projections (projection_id),
  generation_key TEXT NOT NULL,
  generation INTEGER NOT NULL CHECK (generation > 0),
  materializer_actor TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (projection_id, generation_key)
)]],
}
local TABLES = {"bee_credential_generations", "bee_credential_projections", "bee_credential_epochs", "bee_credential_definitions"}

return require("migration").define(function()
    migration("Create credential definitions and projections", function()
        database("sqlite", function()
            up(function(db)
                for _, statement in ipairs(STATEMENTS) do
                    local _, err = db:execute(statement)
                    if err then error(err) end
                end
            end)
            down(function(db)
                for _, name in ipairs(TABLES) do
                    local _, err = db:execute("DROP TABLE IF EXISTS " .. name)
                    if err then error(err) end
                end
            end)
        end)
    end)
end)
