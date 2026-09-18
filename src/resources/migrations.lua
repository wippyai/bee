-- MIT. The resource authority schema as an ordered ledger. Migration text
-- is part of its checksum; a change is a new migration.
local M = {}
type Migration = {id: integer, name: string, sql: string, rebuild: boolean}
local RESOURCES_SQL = [[
CREATE TABLE bee_resource_associations (
    workspace_id TEXT NOT NULL,
    name TEXT NOT NULL,
    association_id TEXT NOT NULL UNIQUE,
    revision INTEGER NOT NULL CHECK (revision > 0),
    root_ref TEXT NOT NULL,
    root_digest TEXT NOT NULL,
    subpath TEXT NOT NULL,
    allowed_access TEXT NOT NULL CHECK (allowed_access IN ('read', 'write')),
    owner_node TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (workspace_id, name)
);
CREATE TABLE bee_resource_epochs (
    workspace_id TEXT PRIMARY KEY,
    epoch INTEGER NOT NULL CHECK (epoch >= 0)
);
CREATE TABLE bee_resource_grants (
    grant_id TEXT PRIMARY KEY,
    workspace_id TEXT NOT NULL,
    name TEXT NOT NULL,
    association_id TEXT NOT NULL,
    association_revision INTEGER NOT NULL CHECK (association_revision > 0),
    issuer_owner TEXT NOT NULL,
    subject TEXT NOT NULL,
    audience TEXT NOT NULL,
    root_ref TEXT NOT NULL,
    root_digest TEXT NOT NULL,
    subpath TEXT NOT NULL,
    access TEXT NOT NULL CHECK (access IN ('read', 'write')),
    purpose TEXT NOT NULL CHECK (purpose IN ('project', 'output', 'cache', 'session')),
    attempt_id TEXT,
    expires_at TEXT NOT NULL,
    authorization_epoch INTEGER NOT NULL CHECK (authorization_epoch >= 0),
    revoked_at TEXT,
    idempotency_key TEXT,
    request_digest TEXT,
    created_at TEXT NOT NULL,
    UNIQUE (subject, idempotency_key)
);
CREATE INDEX bee_resource_grants_workspace ON bee_resource_grants (workspace_id, name);
]]
local list: {Migration} = {
    {id = 1, name = "resources", sql = RESOURCES_SQL, rebuild = false},
}
function M.all(): {Migration}
    return list
end
return M
