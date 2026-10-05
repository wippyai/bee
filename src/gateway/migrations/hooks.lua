-- MIT. Hook intake: a binding names the hook events it admits and can be
-- sealed before it is revoked, each credential has a kind, tool or hook, and
-- hook submissions queue per binding until the attempt's carrier commits
-- them to its thread.
local STATEMENTS = {
    "ALTER TABLE bee_gateway_bindings ADD COLUMN hooks_json TEXT NOT NULL DEFAULT '[]'",
    "ALTER TABLE bee_gateway_bindings ADD COLUMN sealed_at TEXT",
    [[CREATE TABLE bee_gateway_credentials_next (
  credential_id TEXT PRIMARY KEY,
  binding_id TEXT NOT NULL REFERENCES bee_gateway_bindings (binding_id),
  generation INTEGER NOT NULL CHECK (generation > 0),
  kind TEXT NOT NULL CHECK (kind IN ('tool', 'hook')),
  token_hash TEXT NOT NULL UNIQUE CHECK (length(token_hash) = 64),
  materialized_by TEXT NOT NULL,
  materialized_at TEXT NOT NULL,
  presented_count INTEGER NOT NULL DEFAULT 0,
  last_presented_at TEXT,
  UNIQUE (binding_id, generation, kind)
)]],
    [[INSERT INTO bee_gateway_credentials_next (credential_id, binding_id, generation, kind, token_hash, materialized_by, materialized_at, presented_count, last_presented_at)
  SELECT credential_id, binding_id, generation, 'tool', token_hash, materialized_by, materialized_at, presented_count, last_presented_at FROM bee_gateway_credentials]],
    "DROP TABLE bee_gateway_credentials",
    "ALTER TABLE bee_gateway_credentials_next RENAME TO bee_gateway_credentials",
    [[CREATE TABLE bee_gateway_hooks (
  event_id TEXT PRIMARY KEY,
  binding_id TEXT NOT NULL REFERENCES bee_gateway_bindings (binding_id),
  attempt_id TEXT NOT NULL,
  action_id TEXT NOT NULL,
  carrier_epoch INTEGER NOT NULL,
  event TEXT NOT NULL,
  occurrence TEXT NOT NULL,
  ambiguous INTEGER NOT NULL CHECK (ambiguous IN (0, 1)),
  digest TEXT NOT NULL,
  fields_json TEXT NOT NULL,
  provenance TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('queued', 'committed', 'rejected')),
  claimed_epoch INTEGER NOT NULL DEFAULT 0,
  claimed_at TEXT,
  rejected_reason TEXT,
  sequence INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
)]],
    "CREATE INDEX bee_gateway_hooks_occurrence ON bee_gateway_hooks (binding_id, event, occurrence)",
    "CREATE INDEX bee_gateway_hooks_status ON bee_gateway_hooks (binding_id, status, sequence)",
}

return require("migration").define(function()
    migration("Admit hook events, seal bindings, keep a credential per kind and queue hook submissions", function()
        database("sqlite", function()
            up(function(db)
                for _, statement in ipairs(STATEMENTS) do
                    local _, err = db:execute(statement)
                    if err then error(err) end
                end
            end)
            down(function(db)
                local _, err = db:execute("DROP TABLE IF EXISTS bee_gateway_hooks")
                if err then error(err) end
            end)
        end)
    end)
end)
