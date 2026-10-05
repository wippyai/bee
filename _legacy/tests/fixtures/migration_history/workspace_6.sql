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
