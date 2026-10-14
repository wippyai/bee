-- MIT. The gateway store: bindings that stand for an admitted attempt, the
-- hashes of the credentials minted for them and each binding's MCP surface.
-- TABLES lists them in the order they are dropped.
local M = {}
M.STATEMENTS = {
    [[CREATE TABLE bee_gateway_bindings (
  binding_id TEXT PRIMARY KEY,
  subject TEXT NOT NULL,
  action_id TEXT NOT NULL,
  attempt_id TEXT NOT NULL,
  thread_id TEXT NOT NULL,
  carrier_epoch INTEGER NOT NULL CHECK (carrier_epoch > 0),
  tools_json TEXT NOT NULL,
  listener_key TEXT NOT NULL,
  credential_generation INTEGER NOT NULL CHECK (credential_generation >= 0),
  revoked_at TEXT,
  request_digest TEXT NOT NULL,
  created_at TEXT NOT NULL,
  policy_ref TEXT,
  workspace_id TEXT
)]],
    [[CREATE INDEX bee_gateway_bindings_attempt ON bee_gateway_bindings (attempt_id, carrier_epoch)]],
    [[CREATE TABLE bee_gateway_credentials (
  credential_id TEXT PRIMARY KEY,
  binding_id TEXT NOT NULL REFERENCES bee_gateway_bindings (binding_id),
  generation INTEGER NOT NULL CHECK (generation > 0),
  token_hash TEXT NOT NULL UNIQUE CHECK (length(token_hash) = 64),
  materialized_by TEXT NOT NULL,
  materialized_at TEXT NOT NULL,
  presented_count INTEGER NOT NULL DEFAULT 0,
  last_presented_at TEXT,
  UNIQUE (binding_id, generation)
)]],
    [[CREATE TABLE bee_gateway_surfaces (
  binding_id TEXT PRIMARY KEY REFERENCES bee_gateway_bindings (binding_id),
  surface_json TEXT NOT NULL CHECK (length(CAST(surface_json AS BLOB)) BETWEEN 1 AND 131072),
  active_json TEXT NOT NULL CHECK (length(CAST(active_json AS BLOB)) BETWEEN 1 AND 8192),
  context_json TEXT NOT NULL CHECK (length(CAST(context_json AS BLOB)) BETWEEN 1 AND 16384),
  revision INTEGER NOT NULL CHECK (revision BETWEEN 1 AND 9007199254740991)
)]],
}
M.TABLES = {"bee_gateway_surfaces", "bee_gateway_credentials", "bee_gateway_bindings"}
return M
