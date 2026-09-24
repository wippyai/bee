-- MIT. A frozen copy of the applied workspace migrations 1-5 as an existing
-- single-workspace install has them. Applied migrations never change, so the
-- store rejects this ledger if the copy ever diverges from its own history.
local sql = require("sql")
local hash = require("hash")
type Migration = {id: integer, name: string, sql: string}
local M = {}
local STATE_TABLE_SQL = [[
CREATE TABLE IF NOT EXISTS workspace_state (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    schema_version INTEGER NOT NULL CHECK (schema_version = 1),
    generation INTEGER NOT NULL CHECK (generation >= 0),
    value TEXT NOT NULL CHECK (length(CAST(value AS BLOB)) <= 2097152),
    updated_at TEXT NOT NULL
)
]]
local IDENTITY_TABLE_SQL = [[
CREATE TABLE workspace_identity (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    workspace_id TEXT NOT NULL CHECK (
        length(workspace_id) = 32 AND workspace_id NOT GLOB '*[^0-9a-f]*'
    )
);
INSERT INTO workspace_identity (singleton, workspace_id)
VALUES (1, lower(hex(randomblob(16))))
]]
local DISPLAY_ASSIGNMENTS_TABLE_SQL = [[
CREATE TABLE workspace_display_assignments (
    view_id TEXT NOT NULL CHECK (length(CAST(view_id AS BLOB)) BETWEEN 1 AND 80 AND view_id NOT GLOB '*[^ -~]*'),
    instance_id TEXT NOT NULL CHECK (length(CAST(instance_id AS BLOB)) BETWEEN 1 AND 80 AND instance_id NOT GLOB '*[^ -~]*'),
    display_id TEXT NOT NULL CHECK (length(CAST(display_id AS BLOB)) BETWEEN 1 AND 160 AND display_id NOT GLOB '*[^ -~]*'),
    revision INTEGER NOT NULL CHECK (revision >= 1 AND revision <= 9007199254740990),
    PRIMARY KEY (view_id, instance_id)
);
CREATE TABLE workspace_display_transfer_receipts (
    request_id TEXT PRIMARY KEY CHECK (length(CAST(request_id AS BLOB)) BETWEEN 1 AND 80 AND request_id NOT GLOB '*[^ -~]*'),
    view_id TEXT NOT NULL CHECK (length(CAST(view_id AS BLOB)) BETWEEN 1 AND 80 AND view_id NOT GLOB '*[^ -~]*'),
    instance_id TEXT NOT NULL CHECK (length(CAST(instance_id AS BLOB)) BETWEEN 1 AND 80 AND instance_id NOT GLOB '*[^ -~]*'),
    source_display_id TEXT NOT NULL CHECK (length(CAST(source_display_id AS BLOB)) BETWEEN 1 AND 160 AND source_display_id NOT GLOB '*[^ -~]*'),
    target_display_id TEXT NOT NULL CHECK (length(CAST(target_display_id AS BLOB)) BETWEEN 1 AND 160 AND target_display_id NOT GLOB '*[^ -~]*'),
    expected_revision INTEGER NOT NULL CHECK (expected_revision >= 1 AND expected_revision <= 9007199254740990),
    phase TEXT NOT NULL CHECK (phase IN ('prepared', 'committed', 'failed')),
    error TEXT CHECK (error IS NULL OR length(CAST(error AS BLOB)) <= 1024),
    updated_at TEXT NOT NULL
);
CREATE UNIQUE INDEX workspace_display_one_prepared_transfer
ON workspace_display_transfer_receipts (view_id, instance_id)
WHERE phase = 'prepared';
]]
local APPLICATION_THREAD_BINDINGS_TABLE_SQL = [[
CREATE TABLE workspace_application_thread_bindings (
    instance_id TEXT PRIMARY KEY CHECK (length(CAST(instance_id AS BLOB)) BETWEEN 1 AND 80 AND instance_id NOT GLOB '*[^ -~]*'),
    thread_id TEXT NOT NULL CHECK (length(CAST(thread_id AS BLOB)) BETWEEN 1 AND 160 AND thread_id NOT GLOB '*[^ -~]*'),
    definition_id TEXT NOT NULL CHECK (length(CAST(definition_id AS BLOB)) BETWEEN 1 AND 160 AND definition_id NOT GLOB '*[^ -~]*'),
    actor_id TEXT NOT NULL CHECK (length(CAST(actor_id AS BLOB)) BETWEEN 1 AND 160 AND actor_id NOT GLOB '*[^ -~]*'),
    role TEXT NOT NULL CHECK (role = 'participant'),
    binding_revision INTEGER NOT NULL CHECK (binding_revision >= 1 AND binding_revision <= 9007199254740990),
    state TEXT NOT NULL CHECK (state IN ('pending', 'active', 'revoked')),
    idempotency_key TEXT NOT NULL UNIQUE CHECK (length(CAST(idempotency_key AS BLOB)) BETWEEN 1 AND 160 AND idempotency_key NOT GLOB '*[^ -~]*')
);
]]
local APPLICATION_THREAD_BINDINGS_V5_SQL = [[
CREATE TABLE workspace_application_thread_bindings_v5 (
    instance_id TEXT PRIMARY KEY CHECK (length(CAST(instance_id AS BLOB)) BETWEEN 1 AND 80 AND instance_id NOT GLOB '*[^ -~]*'),
    thread_id TEXT NOT NULL CHECK (length(CAST(thread_id AS BLOB)) BETWEEN 1 AND 160 AND thread_id NOT GLOB '*[^ -~]*'),
    definition_id TEXT NOT NULL CHECK (length(CAST(definition_id AS BLOB)) BETWEEN 1 AND 160 AND definition_id NOT GLOB '*[^ -~]*'),
    actor_id TEXT NOT NULL CHECK (length(CAST(actor_id AS BLOB)) BETWEEN 1 AND 160 AND actor_id NOT GLOB '*[^ -~]*'),
    role TEXT NOT NULL CHECK (role = 'participant'),
    binding_revision INTEGER NOT NULL CHECK (binding_revision >= 1 AND binding_revision <= 9007199254740990),
    state TEXT NOT NULL CHECK (state IN ('pending', 'active', 'revoked')),
    idempotency_key TEXT NOT NULL UNIQUE CHECK (length(CAST(idempotency_key AS BLOB)) BETWEEN 1 AND 160 AND idempotency_key NOT GLOB '*[^ -~]*'),
    definition_revision TEXT NOT NULL CHECK (length(CAST(definition_revision AS BLOB)) BETWEEN 1 AND 80 AND definition_revision NOT GLOB '*[^ -~]*'),
    initiating_owner_id TEXT NOT NULL CHECK (length(CAST(initiating_owner_id AS BLOB)) BETWEEN 1 AND 160 AND initiating_owner_id NOT GLOB '*[^ -~]*'),
    gateway_binding_id TEXT NOT NULL CHECK (length(CAST(gateway_binding_id AS BLOB)) BETWEEN 1 AND 160 AND gateway_binding_id NOT GLOB '*[^ -~]*'),
    gateway_approval_id TEXT NOT NULL CHECK (length(CAST(gateway_approval_id AS BLOB)) BETWEEN 1 AND 160 AND gateway_approval_id NOT GLOB '*[^ -~]*'),
    gateway_proposal_digest TEXT NOT NULL CHECK (length(gateway_proposal_digest) = 64 AND gateway_proposal_digest NOT GLOB '*[^0-9a-f]*'),
    access TEXT NOT NULL CHECK (access = 'observe_post'),
    join_expected_revision INTEGER NOT NULL CHECK (join_expected_revision >= 1 AND join_expected_revision <= 9007199254740990),
    membership_revision INTEGER CHECK (membership_revision IS NULL OR (membership_revision >= 1 AND membership_revision <= 9007199254740990)),
    cleanup_pending INTEGER NOT NULL CHECK (cleanup_pending IN (0, 1)),
    cleanup_expected_revision INTEGER CHECK (cleanup_expected_revision IS NULL OR (cleanup_expected_revision >= 1 AND cleanup_expected_revision <= 9007199254740990))
);
INSERT INTO workspace_application_thread_bindings_v5
    (instance_id, thread_id, definition_id, actor_id, role, binding_revision, state, idempotency_key,
     definition_revision, initiating_owner_id, gateway_binding_id, gateway_approval_id,
     gateway_proposal_digest, access, join_expected_revision, membership_revision,
     cleanup_pending, cleanup_expected_revision)
SELECT instance_id, thread_id, definition_id, actor_id, role, binding_revision, 'revoked', idempotency_key,
    'migration-unbound', 'migration-unbound', 'migration-unbound', 'migration-unbound', lower(hex(zeroblob(32))),
    'observe_post', 1, NULL, 0, NULL
FROM workspace_application_thread_bindings;
DROP TABLE workspace_application_thread_bindings;
ALTER TABLE workspace_application_thread_bindings_v5 RENAME TO workspace_application_thread_bindings;
]]
local migrations: {Migration} = {
    {id = 1, name = "workspace_state_v1", sql = STATE_TABLE_SQL},
    {id = 2, name = "workspace_identity_v1", sql = IDENTITY_TABLE_SQL},
    {id = 3, name = "workspace_display_assignments_v1", sql = DISPLAY_ASSIGNMENTS_TABLE_SQL},
    {id = 4, name = "workspace_application_thread_bindings_v1", sql = APPLICATION_THREAD_BINDINGS_TABLE_SQL},
    {id = 5, name = "workspace_application_thread_bindings_v2", sql = APPLICATION_THREAD_BINDINGS_V5_SQL},
}
-- Apply migrations 1..5 with their ledger rows, as the previous build did.
function M.build(db: sql.DB): (boolean, string?)
    local _, ledger_error = db:execute([[CREATE TABLE workspace_schema_migrations (
    id INTEGER PRIMARY KEY CHECK (id > 0),
    name TEXT NOT NULL,
    checksum TEXT NOT NULL,
    applied_at TEXT NOT NULL,
    UNIQUE (name)
)]])
    if ledger_error then return false, tostring(ledger_error) end
    for _, migration in ipairs(migrations) do
        local checksum, hash_error = hash.sha256(migration.name .. "\n" .. migration.sql)
        if not checksum then return false, tostring(hash_error) end
        local _, apply_error = db:execute(migration.sql)
        if apply_error then return false, tostring(apply_error) end
        local _, record_error = db:execute("INSERT INTO workspace_schema_migrations (id, name, checksum, applied_at) VALUES (?, ?, ?, 'before')",
            {migration.id, migration.name, checksum})
        if record_error then return false, tostring(record_error) end
    end
    return true, nil
end
return M
