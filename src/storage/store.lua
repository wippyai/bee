-- The node workspace catalog and the durable state of each workspace, keyed by workspace_id.
--
-- The host selects a reserved registry resource under an exact database policy.
-- Registry configuration owns its file and lifecycle. Applications cannot import
-- this library and their database boundary denies the reserved store namespaces.
local sql = require("sql")
local json = require("json")
local hash = require("hash")
local binding = require("binding")
local contract = require("contract")

type Migration = {id: integer, name: string, sql: string}
type Store = {
    db: sql.DB,
    closed: boolean,
    workspace_id: string,
    generation: integer?,
    identity: (Store) -> (string?, string?),
    read: (Store) -> (string?, string?),
    write: (Store, string) -> (boolean, string?),
    close: (Store) -> (boolean, string?),
}

local M = {}

local STATE_VERSION = 1
local MAX_STATE_BYTES = 2097152
local MIGRATION_TABLE = "workspace_schema_migrations"
local STATE_TABLE = "workspace_state"

-- This table is an append-only ledger from the library's point of view.  The
-- name and checksum are checked on every open, so editing an applied
-- migration cannot silently reinterpret an existing workspace.
local MIGRATION_TABLE_SQL = [[
CREATE TABLE IF NOT EXISTS workspace_schema_migrations (
    id INTEGER PRIMARY KEY CHECK (id > 0),
    name TEXT NOT NULL,
    checksum TEXT NOT NULL,
    applied_at TEXT NOT NULL,
    UNIQUE (name)
)
]]

local STATE_TABLE_SQL = [[
CREATE TABLE IF NOT EXISTS workspace_state (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    schema_version INTEGER NOT NULL CHECK (schema_version = 1),
    generation INTEGER NOT NULL CHECK (generation >= 0),
    value TEXT NOT NULL CHECK (length(CAST(value AS BLOB)) <= 2097152),
    updated_at TEXT NOT NULL
)
]]

-- Identity is independent from the mutable desktop envelope, folder and host.
-- Seed it only as part of the migration: a missing row on later opens is corrupt.
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

-- Workspace-owned display decisions.  These rows deliberately contain no
-- process, viewport, mount, or client connection identifiers.  A prepared
-- transfer remains durable after a host crash so recovery can fence a stale
-- source layout before a controller bind is considered.
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

-- The workspace owner keeps one immutable logical application/thread binding.
-- Runtime execution details and thread membership remain owned by their
-- respective authorities and are deliberately absent from this table.
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

-- Migration 5 closes the lifecycle gap in the first binding table without
-- rewriting its applied SQL.  Existing migration-4 rows were never consumed
-- by a membership owner, so they become explicit, cleanup-complete tombstones
-- rather than being interpreted as live authority after an upgrade.
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

-- Migration 6 turns the database into the node's workspace catalog. A
-- workspace is a row: identity moves from the singleton identity table into
-- `workspaces`, and every workspace-owned table is rebuilt with workspace_id as
-- its leading key. Existing rows keep their values under the migrated identity.
-- The identity is read through a scalar subquery, so a missing identity row
-- violates NOT NULL and fails the migration instead of dropping state.
local NODE_WORKSPACES_SQL = [[
CREATE TABLE workspaces (
    workspace_id TEXT NOT NULL PRIMARY KEY CHECK (length(workspace_id) = 32 AND workspace_id NOT GLOB '*[^0-9a-f]*'),
    label TEXT NOT NULL CHECK (length(CAST(label AS BLOB)) <= 240),
    root_ref TEXT NOT NULL CHECK (length(CAST(root_ref AS BLOB)) BETWEEN 1 AND 160),
    subpath TEXT NOT NULL CHECK (length(CAST(subpath AS BLOB)) <= 1024),
    state TEXT NOT NULL CHECK (state IN ('active', 'archived')),
    created_at TEXT NOT NULL,
    last_used_at TEXT NOT NULL,
    UNIQUE (root_ref, subpath)
);
INSERT INTO workspaces (workspace_id, label, root_ref, subpath, state, created_at, last_used_at)
SELECT (SELECT workspace_id FROM workspace_identity WHERE singleton = 1), '', 'bee:workspace_root', '', 'active',
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), strftime('%Y-%m-%dT%H:%M:%fZ', 'now');
CREATE TABLE workspace_state_v6 (
    workspace_id TEXT NOT NULL PRIMARY KEY CHECK (length(workspace_id) = 32 AND workspace_id NOT GLOB '*[^0-9a-f]*'),
    schema_version INTEGER NOT NULL CHECK (schema_version = 1),
    generation INTEGER NOT NULL CHECK (generation >= 0),
    value TEXT NOT NULL CHECK (length(CAST(value AS BLOB)) <= 2097152),
    updated_at TEXT NOT NULL
);
INSERT INTO workspace_state_v6 (workspace_id, schema_version, generation, value, updated_at)
SELECT (SELECT workspace_id FROM workspace_identity WHERE singleton = 1), schema_version, generation, value, updated_at
FROM workspace_state;
DROP TABLE workspace_state;
ALTER TABLE workspace_state_v6 RENAME TO workspace_state;
CREATE TABLE workspace_display_assignments_v6 (
    workspace_id TEXT NOT NULL CHECK (length(workspace_id) = 32 AND workspace_id NOT GLOB '*[^0-9a-f]*'),
    view_id TEXT NOT NULL CHECK (length(CAST(view_id AS BLOB)) BETWEEN 1 AND 80 AND view_id NOT GLOB '*[^ -~]*'),
    instance_id TEXT NOT NULL CHECK (length(CAST(instance_id AS BLOB)) BETWEEN 1 AND 80 AND instance_id NOT GLOB '*[^ -~]*'),
    display_id TEXT NOT NULL CHECK (length(CAST(display_id AS BLOB)) BETWEEN 1 AND 160 AND display_id NOT GLOB '*[^ -~]*'),
    revision INTEGER NOT NULL CHECK (revision >= 1 AND revision <= 9007199254740990),
    PRIMARY KEY (workspace_id, view_id, instance_id)
);
INSERT INTO workspace_display_assignments_v6 (workspace_id, view_id, instance_id, display_id, revision)
SELECT (SELECT workspace_id FROM workspace_identity WHERE singleton = 1), view_id, instance_id, display_id, revision
FROM workspace_display_assignments;
DROP TABLE workspace_display_assignments;
ALTER TABLE workspace_display_assignments_v6 RENAME TO workspace_display_assignments;
CREATE TABLE workspace_display_transfer_receipts_v6 (
    workspace_id TEXT NOT NULL CHECK (length(workspace_id) = 32 AND workspace_id NOT GLOB '*[^0-9a-f]*'),
    request_id TEXT NOT NULL CHECK (length(CAST(request_id AS BLOB)) BETWEEN 1 AND 80 AND request_id NOT GLOB '*[^ -~]*'),
    view_id TEXT NOT NULL CHECK (length(CAST(view_id AS BLOB)) BETWEEN 1 AND 80 AND view_id NOT GLOB '*[^ -~]*'),
    instance_id TEXT NOT NULL CHECK (length(CAST(instance_id AS BLOB)) BETWEEN 1 AND 80 AND instance_id NOT GLOB '*[^ -~]*'),
    source_display_id TEXT NOT NULL CHECK (length(CAST(source_display_id AS BLOB)) BETWEEN 1 AND 160 AND source_display_id NOT GLOB '*[^ -~]*'),
    target_display_id TEXT NOT NULL CHECK (length(CAST(target_display_id AS BLOB)) BETWEEN 1 AND 160 AND target_display_id NOT GLOB '*[^ -~]*'),
    expected_revision INTEGER NOT NULL CHECK (expected_revision >= 1 AND expected_revision <= 9007199254740990),
    phase TEXT NOT NULL CHECK (phase IN ('prepared', 'committed', 'failed')),
    error TEXT CHECK (error IS NULL OR length(CAST(error AS BLOB)) <= 1024),
    updated_at TEXT NOT NULL,
    PRIMARY KEY (workspace_id, request_id)
);
INSERT INTO workspace_display_transfer_receipts_v6
    (workspace_id, request_id, view_id, instance_id, source_display_id, target_display_id, expected_revision, phase, error, updated_at)
SELECT (SELECT workspace_id FROM workspace_identity WHERE singleton = 1), request_id, view_id, instance_id,
    source_display_id, target_display_id, expected_revision, phase, error, updated_at
FROM workspace_display_transfer_receipts;
DROP TABLE workspace_display_transfer_receipts;
ALTER TABLE workspace_display_transfer_receipts_v6 RENAME TO workspace_display_transfer_receipts;
CREATE UNIQUE INDEX workspace_display_one_prepared_transfer
ON workspace_display_transfer_receipts (workspace_id, view_id, instance_id)
WHERE phase = 'prepared';
CREATE TABLE workspace_application_thread_bindings_v6 (
    workspace_id TEXT NOT NULL CHECK (length(workspace_id) = 32 AND workspace_id NOT GLOB '*[^0-9a-f]*'),
    instance_id TEXT NOT NULL CHECK (length(CAST(instance_id AS BLOB)) BETWEEN 1 AND 80 AND instance_id NOT GLOB '*[^ -~]*'),
    thread_id TEXT NOT NULL CHECK (length(CAST(thread_id AS BLOB)) BETWEEN 1 AND 160 AND thread_id NOT GLOB '*[^ -~]*'),
    definition_id TEXT NOT NULL CHECK (length(CAST(definition_id AS BLOB)) BETWEEN 1 AND 160 AND definition_id NOT GLOB '*[^ -~]*'),
    actor_id TEXT NOT NULL CHECK (length(CAST(actor_id AS BLOB)) BETWEEN 1 AND 160 AND actor_id NOT GLOB '*[^ -~]*'),
    role TEXT NOT NULL CHECK (role = 'participant'),
    binding_revision INTEGER NOT NULL CHECK (binding_revision >= 1 AND binding_revision <= 9007199254740990),
    state TEXT NOT NULL CHECK (state IN ('pending', 'active', 'revoked')),
    idempotency_key TEXT NOT NULL CHECK (length(CAST(idempotency_key AS BLOB)) BETWEEN 1 AND 160 AND idempotency_key NOT GLOB '*[^ -~]*'),
    definition_revision TEXT NOT NULL CHECK (length(CAST(definition_revision AS BLOB)) BETWEEN 1 AND 80 AND definition_revision NOT GLOB '*[^ -~]*'),
    initiating_owner_id TEXT NOT NULL CHECK (length(CAST(initiating_owner_id AS BLOB)) BETWEEN 1 AND 160 AND initiating_owner_id NOT GLOB '*[^ -~]*'),
    gateway_binding_id TEXT NOT NULL CHECK (length(CAST(gateway_binding_id AS BLOB)) BETWEEN 1 AND 160 AND gateway_binding_id NOT GLOB '*[^ -~]*'),
    gateway_approval_id TEXT NOT NULL CHECK (length(CAST(gateway_approval_id AS BLOB)) BETWEEN 1 AND 160 AND gateway_approval_id NOT GLOB '*[^ -~]*'),
    gateway_proposal_digest TEXT NOT NULL CHECK (length(gateway_proposal_digest) = 64 AND gateway_proposal_digest NOT GLOB '*[^0-9a-f]*'),
    access TEXT NOT NULL CHECK (access = 'observe_post'),
    join_expected_revision INTEGER NOT NULL CHECK (join_expected_revision >= 1 AND join_expected_revision <= 9007199254740990),
    membership_revision INTEGER CHECK (membership_revision IS NULL OR (membership_revision >= 1 AND membership_revision <= 9007199254740990)),
    cleanup_pending INTEGER NOT NULL CHECK (cleanup_pending IN (0, 1)),
    cleanup_expected_revision INTEGER CHECK (cleanup_expected_revision IS NULL OR (cleanup_expected_revision >= 1 AND cleanup_expected_revision <= 9007199254740990)),
    PRIMARY KEY (workspace_id, instance_id),
    UNIQUE (workspace_id, idempotency_key)
);
INSERT INTO workspace_application_thread_bindings_v6
    (workspace_id, instance_id, thread_id, definition_id, actor_id, role, binding_revision, state, idempotency_key,
     definition_revision, initiating_owner_id, gateway_binding_id, gateway_approval_id,
     gateway_proposal_digest, access, join_expected_revision, membership_revision,
     cleanup_pending, cleanup_expected_revision)
SELECT (SELECT workspace_id FROM workspace_identity WHERE singleton = 1), instance_id, thread_id, definition_id, actor_id,
    role, binding_revision, state, idempotency_key, definition_revision, initiating_owner_id, gateway_binding_id,
    gateway_approval_id, gateway_proposal_digest, access, join_expected_revision, membership_revision,
    cleanup_pending, cleanup_expected_revision
FROM workspace_application_thread_bindings;
DROP TABLE workspace_application_thread_bindings;
ALTER TABLE workspace_application_thread_bindings_v6 RENAME TO workspace_application_thread_bindings;
DROP TABLE workspace_identity;
]]

-- Migration 7 orders the catalog for paging and search. Listing and label
-- search walk (state, lower(label), workspace_id); path search walks
-- (state, root_ref, subpath). SQLite's lower() folds ASCII only, and queries
-- use the same expression, so the index and the comparison always agree.
local CATALOG_ORDER_SQL = [[
CREATE INDEX workspaces_by_label ON workspaces (state, lower(label), workspace_id);
CREATE INDEX workspaces_by_path ON workspaces (state, root_ref, subpath);
]]

-- Migration 8 moves the creation of the folder workspace's catalog row from
-- the schema to the classic launch path. Migrations 2 and 6 seed a folder row
-- whenever they run; on a new database, the run that also applies this
-- migration, the seed is removed and workspace_folder records that the row is
-- still to be created, so a daemon that never opens the folder holds no folder
-- workspace. A database migrated before keeps its folder row and records it as
-- created: a folder row that later goes missing is never minted again. The
-- runner states in temp.workspace_migration_run whether this run started from
-- an empty ledger.
local FOLDER_ON_OPEN_SQL = [[
CREATE TABLE workspace_folder (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    created INTEGER NOT NULL CHECK (created IN (0, 1))
);
INSERT INTO workspace_folder (singleton, created)
SELECT 1, 1 - (SELECT fresh FROM temp.workspace_migration_run);
DELETE FROM workspaces
WHERE root_ref = 'bee:workspace_root' AND subpath = ''
    AND (SELECT fresh FROM temp.workspace_migration_run) = 1
]]

local migrations: {Migration} = {
    {id = 1, name = "workspace_state_v1", sql = STATE_TABLE_SQL},
    {id = 2, name = "workspace_identity_v1", sql = IDENTITY_TABLE_SQL},
    {id = 3, name = "workspace_display_assignments_v1", sql = DISPLAY_ASSIGNMENTS_TABLE_SQL},
    {id = 4, name = "workspace_application_thread_bindings_v1", sql = APPLICATION_THREAD_BINDINGS_TABLE_SQL},
    {id = 5, name = "workspace_application_thread_bindings_v2", sql = APPLICATION_THREAD_BINDINGS_V5_SQL},
    {id = 6, name = "node_workspaces_v1", sql = NODE_WORKSPACES_SQL},
    {id = 7, name = "workspace_catalog_order_v1", sql = CATALOG_ORDER_SQL},
    {id = 8, name = "workspace_folder_on_open_v1", sql = FOLDER_ON_OPEN_SQL},
}

local function error_text(prefix: string, err: unknown): string
    if err == nil then return prefix end
    return prefix .. ": " .. tostring(err)
end

local function integer(value: unknown): integer?
    if type(value) ~= "number" or value ~= value or value ~= math.floor(value) then return nil end
    return math.floor(value)
end

local function increment_generation(value: integer?): integer
    if not value then return 1 end
    return value + 1
end

local function rollback(tx: sql.Transaction)
    tx:rollback()
end

local function migration_checksum(migration: Migration): (string?, string?)
    local digest, err = hash.sha256(migration.name .. "\n" .. migration.sql)
    if err or not digest then
        return nil, error_text("calculate migration checksum", err)
    end
    return digest, nil
end

local function validate_state(encoded: string): (boolean, string?)
    if #encoded == 0 then return false, "workspace state must not be empty" end
    if #encoded > MAX_STATE_BYTES then
        return false, "workspace state exceeds 2097152 bytes"
    end

    local value: unknown, decode_err = json.decode(encoded)
    if decode_err then return false, error_text("decode workspace state", decode_err) end
    if type(value) ~= "table" then return false, "workspace state must be a JSON object" end
    if value.version ~= STATE_VERSION then
        return false, "unsupported workspace state version"
    end
    return true, nil
end

local function migration_map(): {[integer]: Migration}
    local result: {[integer]: Migration} = {}
    for _, migration in ipairs(migrations) do result[migration.id] = migration end
    return result
end

local function migrate(db: sql.DB): (boolean, string?)
    local tx, begin_err = db:begin()
    if not tx then return false, error_text("begin workspace migration", begin_err) end

    local _, create_err = tx:execute(MIGRATION_TABLE_SQL)
    if create_err then
        rollback(tx)
        return false, error_text("create workspace migration ledger", create_err)
    end

    local rows, query_err = tx:query(
        "SELECT id, name, checksum FROM workspace_schema_migrations ORDER BY id")
    if query_err or not rows then
        rollback(tx)
        return false, error_text("read workspace migration ledger", query_err)
    end

    -- Migrations read whether this run starts a new database from a
    -- connection-local table that never reaches the file.
    local _, run_err = tx:execute("CREATE TEMP TABLE IF NOT EXISTS workspace_migration_run (fresh INTEGER NOT NULL CHECK (fresh IN (0, 1)))")
    if not run_err then _, run_err = tx:execute("DELETE FROM temp.workspace_migration_run") end
    if not run_err then _, run_err = tx:execute("INSERT INTO temp.workspace_migration_run (fresh) VALUES (?)", {#rows == 0 and 1 or 0}) end
    if run_err then
        rollback(tx)
        return false, error_text("record workspace migration run", run_err)
    end

    local known: {[integer]: boolean} = {}
    local by_id = migration_map()
    local expected_id = 1
    for _, row in ipairs(rows) do
        local id = integer(row.id)
        local name: unknown = row.name
        local checksum: unknown = row.checksum
        if not id or id < 1 then
            rollback(tx)
            return false, "workspace migration ledger contains an invalid id"
        end
        if id ~= expected_id then
            rollback(tx)
            if id > #migrations then
                return false, "workspace database schema is newer than this Bee build"
            end
            return false, "workspace migration ledger has a missing migration"
        end
        if id > #migrations then
            rollback(tx)
            return false, "workspace database schema is newer than this Bee build"
        end
        local migration = by_id[id]
        if not migration or type(name) ~= "string" or type(checksum) ~= "string" then
            rollback(tx)
            return false, "workspace migration ledger is invalid"
        end
        local expected_checksum, checksum_err = migration_checksum(migration)
        if checksum_err or not expected_checksum then
            rollback(tx)
            return false, checksum_err or "workspace migration checksum is unavailable"
        end
        if name ~= migration.name then
            rollback(tx)
            return false, "workspace migration name changed for id " .. tostring(id)
        end
        if checksum ~= expected_checksum then
            rollback(tx)
            return false, "workspace migration checksum changed for id " .. tostring(id)
        end
        known[id] = true
        expected_id = expected_id + 1
    end

    for _, migration in ipairs(migrations) do
        if not known[migration.id] then
            local checksum, checksum_err = migration_checksum(migration)
            if checksum_err or not checksum then
                rollback(tx)
                return false, checksum_err or "workspace migration checksum is unavailable"
            end
            local _, apply_err = tx:execute(migration.sql)
            if apply_err then
                rollback(tx)
                return false, error_text("apply workspace migration " .. migration.name, apply_err)
            end
            local _, record_err = tx:execute(
                "INSERT INTO workspace_schema_migrations (id, name, checksum, applied_at) " ..
                "VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))",
                {migration.id, migration.name, checksum})
            if record_err then
                rollback(tx)
                return false, error_text("record workspace migration " .. migration.name, record_err)
            end
        end
    end

    local _, commit_err = tx:commit()
    if commit_err then
        rollback(tx)
        return false, error_text("commit workspace migration", commit_err)
    end
    return true, nil
end

local function ensure_open(store: Store): string?
    if store.closed then return "workspace store is closed" end
    return nil
end

local function read_identity(store: Store): (string?, string?)
    local closed_err = ensure_open(store)
    if closed_err then return nil, closed_err end
    return store.workspace_id, nil
end

local function read_state(store: Store): (string?, string?)
    local closed_err = ensure_open(store)
    if closed_err then return nil, closed_err end

    local rows, query_err = store.db:query(
        "SELECT schema_version, generation, value FROM workspace_state WHERE workspace_id = ?", {store.workspace_id})
    if query_err or not rows then
        return nil, error_text("read workspace state", query_err)
    end
    if #rows == 0 then
        store.generation = nil
        return nil, nil
    end
    if #rows ~= 1 then return nil, "workspace state row is corrupt" end

    local row = rows[1]
    local schema_version = integer(row.schema_version)
    local generation = integer(row.generation)
    local value: unknown = row.value
    if schema_version ~= STATE_VERSION or not generation or generation < 1 or type(value) ~= "string" then
        return nil, "workspace state row is corrupt"
    end
    local valid, validation_err = validate_state(value)
    if not valid then return nil, validation_err or "workspace state is invalid" end
    store.generation = generation
    return value, nil
end

local function write_state(store: Store, value: string): (boolean, string?)
    local closed_err = ensure_open(store)
    if closed_err then return false, closed_err end
    local valid, validation_err = validate_state(value)
    if not valid then return false, validation_err or "workspace state is invalid" end

    -- Pin the generation observed by this handle.  A writer must first read
    -- (open() performs that initial read) and cannot overwrite a commit made
    -- by another handle in the meantime.
    local expected_generation = store.generation
    local tx, begin_err = store.db:begin()
    if not tx then return false, error_text("begin workspace write", begin_err) end

    local rows, query_err = tx:query(
        "SELECT schema_version, generation, value FROM workspace_state WHERE workspace_id = ?", {store.workspace_id})
    if query_err or not rows then
        rollback(tx)
        return false, error_text("read workspace state before write", query_err)
    end

    local next_generation = 1
    if #rows > 1 then
        rollback(tx)
        return false, "workspace state row is corrupt"
    elseif #rows == 1 then
        local row = rows[1]
        local schema_version = integer(row.schema_version)
        local generation = integer(row.generation)
        local current_value: unknown = row.value
        if schema_version ~= STATE_VERSION or not generation or generation < 1
            or type(current_value) ~= "string" then
            rollback(tx)
            return false, "workspace state row is corrupt"
        end
        if expected_generation == nil or generation ~= expected_generation then
            rollback(tx)
            return false, "workspace state changed since it was read"
        end
        local current_valid, current_err = validate_state(current_value)
        if not current_valid then
            rollback(tx)
            return false, current_err or "workspace state is invalid"
        end
        next_generation = increment_generation(generation)
        local result, update_err = tx:execute(
            "UPDATE workspace_state SET value = ?, generation = ?, updated_at = " ..
            "strftime('%Y-%m-%dT%H:%M:%fZ', 'now') " ..
            "WHERE workspace_id = ? AND generation = ?",
            {value, next_generation, store.workspace_id, generation})
        if update_err or not result then
            rollback(tx)
            return false, error_text("write workspace state", update_err)
        end
        local affected = integer(result.rows_affected)
        if affected ~= 1 then
            rollback(tx)
            return false, "workspace state changed during write"
        end
    else
        if expected_generation ~= nil then
            rollback(tx)
            return false, "workspace state disappeared since it was read"
        end
        local _, insert_err = tx:execute(
            "INSERT INTO workspace_state (workspace_id, schema_version, generation, value, updated_at) " ..
            "VALUES (?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))",
            {store.workspace_id, STATE_VERSION, next_generation, value})
        if insert_err then
            rollback(tx)
            return false, error_text("create workspace state", insert_err)
        end
    end

    local _, commit_err = tx:commit()
    if commit_err then
        rollback(tx)
        return false, error_text("commit workspace state", commit_err)
    end
    store.generation = next_generation
    return true, nil
end

local function close_store(store: Store): (boolean, string?)
    if store.closed then return true, nil end
    store.closed = true
    local ok, release_err = store.db:release()
    if release_err then return false, error_text("close workspace store", release_err) end
    return ok == true, nil
end

-- Acquire and migrate the node workspace database. Every open verifies the
-- ledger, so a handle never runs against an unknown schema.
local function acquire(resource: string?): (sql.DB?, string?)
    local database_id = binding.database("workspace", resource)
    if not database_id then return nil, "Invalid workspace database binding" end
    local db, acquire_err = sql.get(database_id)
    if not db then return nil, error_text("open workspace database", acquire_err) end

    local db_type, type_err = db:type()
    if type_err or not db_type then
        db:release()
        return nil, error_text("inspect workspace database", type_err)
    end
    if db_type ~= sql.type.SQLITE then
        db:release()
        return nil, "workspace database must be SQLite"
    end

    local _, wal_err = db:execute("PRAGMA journal_mode = WAL")
    if wal_err then
        db:release()
        return nil, error_text("enable workspace WAL mode", wal_err)
    end
    local migrated, migration_err = migrate(db)
    if not migrated then
        db:release()
        return nil, migration_err or "workspace migration failed"
    end
    return db, nil
end

-- The folder workspace's catalog row: an unnamed, active row at the node's
-- workspace root, created with a fresh identity the first time the classic
-- launch path opens the folder, and only while workspace_folder records it as
-- not yet created.
local function create_folder(db: sql.DB): string?
    local tx, begin_err = db:begin()
    if not tx then return error_text("begin folder workspace creation", begin_err) end
    local claimed, claim_err = tx:execute("UPDATE workspace_folder SET created = 1 WHERE singleton = 1 AND created = 0")
    if claim_err or not claimed then
        rollback(tx)
        return error_text("claim the folder workspace", claim_err)
    end
    if integer(claimed.rows_affected) == 1 then
        local _, insert_err = tx:execute(
            "INSERT INTO workspaces (workspace_id, label, root_ref, subpath, state, created_at, last_used_at) " ..
            "VALUES (lower(hex(randomblob(16))), '', ?, '', 'active', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), " ..
            "strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))",
            {binding.CLASSIC_ROOT})
        if insert_err then
            rollback(tx)
            return error_text("create the folder workspace", insert_err)
        end
    end
    local _, commit_err = tx:commit()
    if commit_err then
        rollback(tx)
        return error_text("commit folder workspace creation", commit_err)
    end
    return nil
end

-- Resolve a selection to exactly one active catalog row. Both forms are
-- unique-key probes and record that a host now uses the workspace. The folder
-- selection creates its row on first use.
local function resolve(db: sql.DB, selection: binding.Selection): (string?, string?)
    local rows: {{[string]: unknown}}?
    local query_err: unknown
    local function probe()
        if selection.workspace_id then
            rows, query_err = db:query("SELECT workspace_id, state FROM workspaces WHERE workspace_id = ?",
                {selection.workspace_id})
        else
            rows, query_err = db:query("SELECT workspace_id, state FROM workspaces WHERE root_ref = ? AND subpath = ?",
                {selection.root_ref, selection.subpath})
        end
    end
    probe()
    if not query_err and rows and #rows == 0 and binding.is_classic(selection) then
        local create_err = create_folder(db)
        if create_err then return nil, create_err end
        probe()
    end
    if query_err or not rows then return nil, error_text("read workspace catalog", query_err) end
    if #rows == 0 then return nil, "workspace is not in the node catalog" end
    if #rows ~= 1 then return nil, "workspace catalog row is corrupt" end
    local id = contract.workspace_id(rows[1].workspace_id)
    if not id then return nil, "workspace identity is invalid" end
    if rows[1].state ~= "active" then return nil, "workspace is not active" end
    local result, update_err = db:execute(
        "UPDATE workspaces SET last_used_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE workspace_id = ? AND state = 'active'",
        {id})
    if update_err or not result then return nil, error_text("record workspace use", update_err) end
    if integer(result.rows_affected) ~= 1 then return nil, "workspace changed while opening" end
    return id, nil
end

-- Open the workspace a host serves. The handle is bound to one catalog row;
-- every read and write it issues carries that workspace_id.
function M.open(resource: string?, value: unknown): (Store?, string?)
    local selection = binding.selection(value)
    if not selection then return nil, "Invalid workspace selection" end
    local db, acquire_err = acquire(resource)
    if not db then return nil, acquire_err end
    local workspace_id, resolve_err = resolve(db, selection)
    if not workspace_id then
        db:release()
        return nil, resolve_err
    end

    local store: Store = {
        db = db,
        closed = false,
        workspace_id = workspace_id,
        generation = nil,
        identity = read_identity,
        read = read_state,
        write = write_state,
        close = close_store,
    }
    local _, initial_read_err = read_state(store)
    if initial_read_err then
        store:close()
        return nil, initial_read_err
    end
    return store, nil
end

-- The migrated node workspace database, for the catalog owner operations.
-- Callers release the handle.
function M.database(resource: string?): (sql.DB?, string?)
    return acquire(resource)
end

return M
