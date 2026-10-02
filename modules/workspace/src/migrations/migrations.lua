-- MIT. Immutable workspace migration SQL and descriptors.
local ledger = require("ledger")

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
SELECT (SELECT workspace_id FROM workspace_identity WHERE singleton = 1), '', 'bee.environment:workspace_root', '', 'active',
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
WHERE root_ref = 'bee.environment:workspace_root' AND subpath = ''
    AND (SELECT fresh FROM temp.workspace_migration_run) = 1
]]

-- Migration 9 changes only Bee-owned identities in the catalog and saved
-- application records. The old root spelling in migrations 6 and 8 remains
-- intact because existing ledgers verify those exact bytes.
local NESTED_NAMES_SQL = [[
UPDATE workspaces SET root_ref = 'bee.env:workspace_root'
WHERE root_ref = 'bee.environment:workspace_root';
UPDATE workspace_application_thread_bindings SET definition_id = CASE definition_id
    WHEN 'bee.hive_manager:app' THEN 'bee.hive.manager:app'
    WHEN 'bee.inbox:app' THEN 'bee.approvals.inbox.app:app'
    WHEN 'bee.modules:app' THEN 'bee.hub.modules:app'
    WHEN 'bee.overlays:app' THEN 'bee.gov.overlays:app'
    WHEN 'bee.workspaces:app' THEN 'bee.workspace.manager:app'
    WHEN 'bee.timeline:app' THEN 'bee.threads.timeline:app'
    WHEN 'bee.processes:app' THEN 'bee.host.processes:app'
    ELSE definition_id END;
UPDATE workspace_state SET value =
    replace(replace(replace(replace(replace(replace(replace(value,
    '"definition_id":"bee.hive_manager:app"', '"definition_id":"bee.hive.manager:app"'),
    '"definition_id":"bee.inbox:app"', '"definition_id":"bee.approvals.inbox.app:app"'),
    '"definition_id":"bee.modules:app"', '"definition_id":"bee.hub.modules:app"'),
    '"definition_id":"bee.overlays:app"', '"definition_id":"bee.gov.overlays:app"'),
    '"definition_id":"bee.workspaces:app"', '"definition_id":"bee.workspace.manager:app"'),
    '"definition_id":"bee.timeline:app"', '"definition_id":"bee.threads.timeline:app"'),
    '"definition_id":"bee.processes:app"', '"definition_id":"bee.host.processes:app"')
WHERE instr(value, '"definition_id":"bee.') > 0;
]]

-- Migration 10 moves only saved definition identities for the UI child namespaces.
local APPLICATION_NAMES_SQL = [[
UPDATE workspace_application_thread_bindings SET definition_id = CASE definition_id
    WHEN 'bee.threads.timeline:app' THEN 'bee.threads.timeline.app:app'
    WHEN 'bee.workspace.manager:app' THEN 'bee.workspace.manager.app:app'
    WHEN 'bee.hive.manager:app' THEN 'bee.hive.manager.app:app'
    ELSE definition_id END;
UPDATE workspace_state SET value = replace(replace(replace(value,
    '"definition_id":"bee.threads.timeline:app"', '"definition_id":"bee.threads.timeline.app:app"'),
    '"definition_id":"bee.workspace.manager:app"', '"definition_id":"bee.workspace.manager.app:app"'),
    '"definition_id":"bee.hive.manager:app"', '"definition_id":"bee.hive.manager.app:app"')
WHERE instr(value, '"definition_id":"bee.') > 0;
]]

local MODULES_APPLICATION_NAMES_SQL = [[
UPDATE workspace_application_thread_bindings SET definition_id = 'bee.hub.modules.app:app'
WHERE definition_id = 'bee.hub.modules:app';
UPDATE workspace_state SET value = replace(value,
    '"definition_id":"bee.hub.modules:app"', '"definition_id":"bee.hub.modules.app:app"')
WHERE instr(value, '"definition_id":"bee.hub.modules:app"') > 0;
]]

local APP_CHILD_NAMES_SQL = [[
UPDATE workspace_application_thread_bindings SET definition_id = CASE definition_id
    WHEN 'bee.settings:app' THEN 'bee.settings.app:app'
    WHEN 'bee.console:app' THEN 'bee.console.app:app'
    WHEN 'bee.host.processes:app' THEN 'bee.host.processes.app:app'
    WHEN 'bee.gov.overlays:app' THEN 'bee.gov.overlays.app:app'
    WHEN 'bee.threads.timeline:app' THEN 'bee.threads.timeline.app:app'
    WHEN 'bee.workspace.manager:app' THEN 'bee.workspace.manager.app:app'
    WHEN 'bee.hive.manager:app' THEN 'bee.hive.manager.app:app'
    WHEN 'bee.hive_manager:app' THEN 'bee.hive.manager.app:app'
    WHEN 'bee.inbox:app' THEN 'bee.approvals.inbox.app:app'
    WHEN 'bee.modules:app' THEN 'bee.hub.modules.app:app'
    WHEN 'bee.hub.modules:app' THEN 'bee.hub.modules.app:app'
    WHEN 'bee.overlays:app' THEN 'bee.gov.overlays.app:app'
    WHEN 'bee.workspaces:app' THEN 'bee.workspace.manager.app:app'
    WHEN 'bee.timeline:app' THEN 'bee.threads.timeline.app:app'
    WHEN 'bee.processes:app' THEN 'bee.host.processes.app:app'
    ELSE definition_id END;
UPDATE workspace_state SET value = json_set(value, '$.applications',
    json((SELECT json_group_array(json(json_set(item.value, '$.definition_id',
CASE json_extract(item.value, '$.definition_id')
    WHEN 'bee.settings:app' THEN 'bee.settings.app:app'
    WHEN 'bee.console:app' THEN 'bee.console.app:app'
    WHEN 'bee.host.processes:app' THEN 'bee.host.processes.app:app'
    WHEN 'bee.gov.overlays:app' THEN 'bee.gov.overlays.app:app'
    WHEN 'bee.threads.timeline:app' THEN 'bee.threads.timeline.app:app'
    WHEN 'bee.workspace.manager:app' THEN 'bee.workspace.manager.app:app'
    WHEN 'bee.hive.manager:app' THEN 'bee.hive.manager.app:app'
    WHEN 'bee.hive_manager:app' THEN 'bee.hive.manager.app:app'
    WHEN 'bee.inbox:app' THEN 'bee.approvals.inbox.app:app'
    WHEN 'bee.modules:app' THEN 'bee.hub.modules.app:app'
    WHEN 'bee.hub.modules:app' THEN 'bee.hub.modules.app:app'
    WHEN 'bee.overlays:app' THEN 'bee.gov.overlays.app:app'
    WHEN 'bee.workspaces:app' THEN 'bee.workspace.manager.app:app'
    WHEN 'bee.timeline:app' THEN 'bee.threads.timeline.app:app'
    WHEN 'bee.processes:app' THEN 'bee.host.processes.app:app'
    ELSE json_extract(item.value, '$.definition_id') END)))
          FROM json_each(workspace_state.value, '$.applications') AS item)))
WHERE json_type(value, '$.applications') = 'array' AND EXISTS
    (SELECT 1 FROM json_each(workspace_state.value, '$.applications') AS item
     WHERE json_extract(item.value, '$.definition_id') IN ('bee.settings:app','bee.console:app','bee.host.processes:app','bee.gov.overlays:app','bee.threads.timeline:app','bee.workspace.manager:app','bee.hive.manager:app','bee.hive_manager:app','bee.inbox:app','bee.modules:app','bee.hub.modules:app','bee.overlays:app','bee.workspaces:app','bee.timeline:app','bee.processes:app'));
]]

local migrations: {ledger.Migration} = {
    {id = 1, name = "workspace_state_v1", sql = STATE_TABLE_SQL},
    {id = 2, name = "workspace_identity_v1", sql = IDENTITY_TABLE_SQL},
    {id = 3, name = "workspace_display_assignments_v1", sql = DISPLAY_ASSIGNMENTS_TABLE_SQL},
    {id = 4, name = "workspace_application_thread_bindings_v1", sql = APPLICATION_THREAD_BINDINGS_TABLE_SQL},
    {id = 5, name = "workspace_application_thread_bindings_v2", sql = APPLICATION_THREAD_BINDINGS_V5_SQL},
    {id = 6, name = "node_workspaces_v1", sql = NODE_WORKSPACES_SQL},
    {id = 7, name = "workspace_catalog_order_v1", sql = CATALOG_ORDER_SQL},
    {id = 8, name = "workspace_folder_on_open_v1", sql = FOLDER_ON_OPEN_SQL},
    {id = 9, name = "nested_bee_names_v1", sql = NESTED_NAMES_SQL},
    {id = 10, name = "application_child_names_v1", sql = APPLICATION_NAMES_SQL},
    {id = 11, name = "modules_application_child_names_v1", sql = MODULES_APPLICATION_NAMES_SQL},
    {id = 12, name = "app_child_names_v2", sql = APP_CHILD_NAMES_SQL},
}

return migrations
