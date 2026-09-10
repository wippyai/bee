-- MIT. The gateway schema as an ordered ledger. A migration is immutable
-- once any store applied it, so every change is appended. Migration 3
-- moves token hashes out of bindings into a credentials table keyed by
-- binding and generation, adds the carrier epoch and the credential
-- generation to bindings, and gives the listener a secret; a store opened
-- across it keeps its bindings, and their tokens, as generation 1.
local M = {}
type Migration = {id: integer, name: string, sql: string, rebuild: boolean}
local GATEWAY_SQL = [[
CREATE TABLE bee_gateway_listener (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    epoch INTEGER NOT NULL CHECK (epoch >= 0),
    address TEXT NOT NULL,
    drained INTEGER NOT NULL CHECK (drained IN (0, 1)),
    opened_at TEXT NOT NULL
);
CREATE TABLE bee_gateway_bindings (
    binding_id TEXT PRIMARY KEY,
    token_hash TEXT NOT NULL UNIQUE,
    subject TEXT NOT NULL,
    action_id TEXT NOT NULL,
    attempt_id TEXT NOT NULL,
    thread_id TEXT NOT NULL,
    owner_incarnation INTEGER NOT NULL CHECK (owner_incarnation > 0),
    tools_json TEXT NOT NULL,
    epoch INTEGER NOT NULL CHECK (epoch >= 0),
    expires_at TEXT NOT NULL,
    revoked_at TEXT,
    idempotency_key TEXT,
    request_digest TEXT,
    created_at TEXT NOT NULL
);
CREATE UNIQUE INDEX bee_gateway_bindings_replay
    ON bee_gateway_bindings(subject, idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE INDEX bee_gateway_bindings_action ON bee_gateway_bindings(action_id, attempt_id);
]]
local DRAIN_SQL = [[
ALTER TABLE bee_gateway_listener ADD COLUMN drain_deadline_at TEXT;
]]
local CREDENTIALS_SQL = [[
ALTER TABLE bee_gateway_listener ADD COLUMN secret TEXT NOT NULL DEFAULT '';
CREATE TABLE bee_gateway_bindings_next (
    binding_id TEXT PRIMARY KEY,
    subject TEXT NOT NULL,
    action_id TEXT NOT NULL,
    attempt_id TEXT NOT NULL,
    thread_id TEXT NOT NULL,
    owner_incarnation INTEGER NOT NULL CHECK (owner_incarnation > 0),
    carrier_epoch INTEGER NOT NULL CHECK (carrier_epoch >= 0),
    tools_json TEXT NOT NULL,
    epoch INTEGER NOT NULL CHECK (epoch >= 0),
    credential_generation INTEGER NOT NULL CHECK (credential_generation >= 0),
    expires_at TEXT NOT NULL,
    revoked_at TEXT,
    idempotency_key TEXT,
    request_digest TEXT,
    created_at TEXT NOT NULL
);
INSERT INTO bee_gateway_bindings_next (binding_id, subject, action_id, attempt_id, thread_id, owner_incarnation, carrier_epoch, tools_json, epoch, credential_generation, expires_at, revoked_at, idempotency_key, request_digest, created_at)
    SELECT binding_id, subject, action_id, attempt_id, thread_id, owner_incarnation, 0, tools_json, epoch, 1, expires_at, revoked_at, idempotency_key, request_digest, created_at
    FROM bee_gateway_bindings;
CREATE TABLE bee_gateway_credentials (
    credential_id TEXT PRIMARY KEY,
    binding_id TEXT NOT NULL REFERENCES bee_gateway_bindings(binding_id),
    generation INTEGER NOT NULL CHECK (generation > 0),
    token_hash TEXT NOT NULL UNIQUE,
    runner TEXT NOT NULL,
    materialized_at TEXT NOT NULL,
    revoked_at TEXT,
    UNIQUE (binding_id, generation)
);
INSERT INTO bee_gateway_credentials (credential_id, binding_id, generation, token_hash, runner, materialized_at, revoked_at)
    SELECT binding_id || ':1', binding_id, 1, token_hash, 'admitted before credential generations', created_at, revoked_at
    FROM bee_gateway_bindings;
DROP TABLE bee_gateway_bindings;
ALTER TABLE bee_gateway_bindings_next RENAME TO bee_gateway_bindings;
CREATE UNIQUE INDEX bee_gateway_bindings_replay
    ON bee_gateway_bindings(subject, idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE INDEX bee_gateway_bindings_attempt ON bee_gateway_bindings(attempt_id, carrier_epoch);
]]
-- Migration 4: materialization is authorized per start by placement with a
-- one-time key whose hash lives on the binding until it is used, and a
-- credential counts how often it was presented.
local MATERIALIZATION_SQL = [[
ALTER TABLE bee_gateway_bindings ADD COLUMN materialization_key_hash TEXT;
ALTER TABLE bee_gateway_bindings ADD COLUMN materialization_expires_at TEXT;
ALTER TABLE bee_gateway_credentials ADD COLUMN presented_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE bee_gateway_credentials ADD COLUMN last_presented_at TEXT;
]]
-- Migration 5: a binding may admit hook events; a credential has a kind
-- (tool or hook) so hook submission and tool access are separate
-- authorities; submitted hooks queue in the gateway store until a carrier
-- commits them as records.
local HOOKS_SQL = [[
ALTER TABLE bee_gateway_bindings ADD COLUMN hooks_json TEXT NOT NULL DEFAULT '[]';
CREATE TABLE bee_gateway_credentials_next (
    credential_id TEXT PRIMARY KEY,
    binding_id TEXT NOT NULL REFERENCES bee_gateway_bindings(binding_id),
    generation INTEGER NOT NULL CHECK (generation > 0),
    kind TEXT NOT NULL CHECK (kind IN ('tool', 'hook')),
    token_hash TEXT NOT NULL UNIQUE,
    runner TEXT NOT NULL,
    materialized_at TEXT NOT NULL,
    revoked_at TEXT,
    presented_count INTEGER NOT NULL DEFAULT 0,
    last_presented_at TEXT,
    UNIQUE (binding_id, generation, kind)
);
INSERT INTO bee_gateway_credentials_next (credential_id, binding_id, generation, kind, token_hash, runner, materialized_at, revoked_at, presented_count, last_presented_at)
    SELECT credential_id, binding_id, generation, 'tool', token_hash, runner, materialized_at, revoked_at, presented_count, last_presented_at
    FROM bee_gateway_credentials;
DROP TABLE bee_gateway_credentials;
ALTER TABLE bee_gateway_credentials_next RENAME TO bee_gateway_credentials;
CREATE TABLE bee_gateway_hooks (
    event_id TEXT PRIMARY KEY,
    binding_id TEXT NOT NULL REFERENCES bee_gateway_bindings(binding_id),
    attempt_id TEXT NOT NULL,
    action_id TEXT NOT NULL,
    carrier_epoch INTEGER NOT NULL,
    event TEXT NOT NULL,
    occurrence TEXT NOT NULL,
    ambiguous INTEGER NOT NULL CHECK (ambiguous IN (0, 1)),
    digest TEXT NOT NULL,
    fields_json TEXT NOT NULL,
    provenance TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('queued', 'committed')),
    sequence INTEGER NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX bee_gateway_hooks_occurrence ON bee_gateway_hooks(binding_id, event, occurrence);
CREATE INDEX bee_gateway_hooks_status ON bee_gateway_hooks(binding_id, status);
]]
-- Migration 6: the intake lifecycle. A queued submission is claimed by a
-- carrier epoch, committed once that carrier's thread commit is
-- acknowledged, or rejected with a reason when nothing will commit it.
local INTAKE_SQL = [[
CREATE TABLE bee_gateway_hooks_next (
    event_id TEXT PRIMARY KEY,
    binding_id TEXT NOT NULL REFERENCES bee_gateway_bindings(binding_id),
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
);
INSERT INTO bee_gateway_hooks_next (event_id, binding_id, attempt_id, action_id, carrier_epoch, event, occurrence, ambiguous, digest, fields_json, provenance, status, claimed_epoch, claimed_at, rejected_reason, sequence, created_at, updated_at)
    SELECT event_id, binding_id, attempt_id, action_id, carrier_epoch, event, occurrence, ambiguous, digest, fields_json, provenance, status, 0, NULL, NULL, sequence, created_at, updated_at
    FROM bee_gateway_hooks;
DROP TABLE bee_gateway_hooks;
ALTER TABLE bee_gateway_hooks_next RENAME TO bee_gateway_hooks;
CREATE INDEX bee_gateway_hooks_occurrence ON bee_gateway_hooks(binding_id, event, occurrence);
CREATE INDEX bee_gateway_hooks_status ON bee_gateway_hooks(binding_id, status, sequence);
]]
-- Migration 7: a binding's intake can be sealed before it is revoked, so a
-- child's exit stops new submissions while what was accepted still drains.
local SEAL_SQL = [[
ALTER TABLE bee_gateway_bindings ADD COLUMN sealed_at TEXT;
]]
function M.all(): {Migration}
    return {{id = 1, name = "gateway", sql = GATEWAY_SQL, rebuild = false}, {id = 2, name = "drain_deadline", sql = DRAIN_SQL, rebuild = false},
        {id = 3, name = "credentials", sql = CREDENTIALS_SQL, rebuild = true}, {id = 4, name = "materialization", sql = MATERIALIZATION_SQL, rebuild = false},
        {id = 5, name = "hooks", sql = HOOKS_SQL, rebuild = true}, {id = 6, name = "intake", sql = INTAKE_SQL, rebuild = true},
        {id = 7, name = "seal", sql = SEAL_SQL, rebuild = false}}
end
return M
