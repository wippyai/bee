local M = {}
type Migration = {id: integer, name: string, sql: string, rebuild: boolean, historical_sql: {string}?}
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
-- Native listener identity fences address reuse and service replacement.
local NATIVE_LISTENER_SQL = [[
ALTER TABLE bee_gateway_listener ADD COLUMN native_key TEXT;
]]
local SURFACE_SQL = [[
CREATE TABLE bee_gateway_surfaces (
    binding_id TEXT PRIMARY KEY REFERENCES bee_gateway_bindings(binding_id),
    surface_json TEXT NOT NULL CHECK(length(CAST(surface_json AS BLOB)) BETWEEN 1 AND 131072),
    active_json TEXT NOT NULL CHECK(length(CAST(active_json AS BLOB)) BETWEEN 1 AND 8192),
    context_json TEXT NOT NULL CHECK(length(CAST(context_json AS BLOB)) BETWEEN 1 AND 16384),
    revision INTEGER NOT NULL CHECK(revision BETWEEN 1 AND 9007199254740991)
);
]]
-- Approval decisions stay with their owner; these are gateway effect receipts.
local ACCESS_SQL = [[
CREATE TABLE bee_gateway_access_grants (
    binding_id TEXT NOT NULL REFERENCES bee_gateway_bindings(binding_id),
    approval_id TEXT NOT NULL,
    proposal_digest TEXT NOT NULL CHECK(length(proposal_digest) = 64),
    traits_json TEXT NOT NULL CHECK(length(CAST(traits_json AS BLOB)) BETWEEN 1 AND 8192),
    PRIMARY KEY(binding_id, approval_id)
);
]]
-- Migration 11: a binding records the launch policy and workspace the
-- attempt ran under, so a gateway tool can read the caller's own agent-launch
-- allow-list and start a child in the caller's workspace. Both grant nothing
-- by themselves; old bindings have none and launch nothing.
local POLICY_SQL = [[
ALTER TABLE bee_gateway_bindings ADD COLUMN policy_ref TEXT;
ALTER TABLE bee_gateway_bindings ADD COLUMN workspace_id TEXT;
]]
-- Migration 12: window launches may bind their gateway to the host-selected
-- origin view. Headless bindings keep this nullable and remain unassigned.
local ORIGIN_VIEW_SQL = [[
ALTER TABLE bee_gateway_bindings ADD COLUMN origin_view_json TEXT;
]]
-- Migration 13: session discovery lists the live bindings of one workspace.
local WORKSPACE_SESSIONS_SQL = [[
CREATE INDEX bee_gateway_bindings_workspace_live
    ON bee_gateway_bindings(workspace_id, created_at) WHERE revoked_at IS NULL AND workspace_id IS NOT NULL;
]]
-- The admitting host may assign a workspace-local name. Existing sessions
-- retain their action ID as their stable default name.
local SESSION_NAMES_SQL = [[
ALTER TABLE bee_gateway_bindings ADD COLUMN workspace_name TEXT;
UPDATE bee_gateway_bindings SET workspace_name = action_id WHERE workspace_name IS NULL;
CREATE INDEX bee_gateway_bindings_workspace_name
    ON bee_gateway_bindings(workspace_id, workspace_name) WHERE revoked_at IS NULL AND workspace_id IS NOT NULL;
]]
local APP_SDK_SQL = [[
UPDATE bee_gateway_surfaces SET surface_json = replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(surface_json, '"bee.application:definition"', '"bee.app:definition"'), '"bee.application:dependency_threads"', '"bee.app:dependency_threads"'), '"bee.application:client"', '"bee.app:client"'), '"bee.application:sessions_protocol"', '"bee.app:sessions_protocol"'), '"bee.application:sessions"', '"bee.app:sessions"'), '"bee.application:arguments"', '"bee.app:arguments"'), '"bee.application:text"', '"bee.app:text"'), '"bee.application:caller"', '"bee.app:caller"'), '"bee.application:folder_picker"', '"bee.app:folder_picker"'), '"bee.application:agent_protocol"', '"bee.app:agent_protocol"'), '"bee.application:host_leases"', '"bee.app:host_leases"'), '"bee.application:status_reader"', '"bee.app:status_reader"'), '"bee.application:status_surface"', '"bee.app:status_surface"'), '"bee.application:interaction"', '"bee.app:interaction"'), '"bee.application:appearance"', '"bee.app:appearance"'), '"bee.application:frame"', '"bee.app:frame"'), '"bee.application:names"', '"bee.app:names"'), '"bee.application:thread_protocol"', '"bee.app:thread_protocol"'), '"bee.application:viz"', '"bee.app:viz"'), '"bee.application:forms"', '"bee.app:forms"'), '"bee.application:diagram"', '"bee.app:diagram"'), '"bee.application:runtime"', '"bee.app:runtime"') WHERE instr(surface_json, 'bee.application:') > 0;
UPDATE bee_gateway_surfaces SET active_json = replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(active_json, '"bee.application:definition"', '"bee.app:definition"'), '"bee.application:dependency_threads"', '"bee.app:dependency_threads"'), '"bee.application:client"', '"bee.app:client"'), '"bee.application:sessions_protocol"', '"bee.app:sessions_protocol"'), '"bee.application:sessions"', '"bee.app:sessions"'), '"bee.application:arguments"', '"bee.app:arguments"'), '"bee.application:text"', '"bee.app:text"'), '"bee.application:caller"', '"bee.app:caller"'), '"bee.application:folder_picker"', '"bee.app:folder_picker"'), '"bee.application:agent_protocol"', '"bee.app:agent_protocol"'), '"bee.application:host_leases"', '"bee.app:host_leases"'), '"bee.application:status_reader"', '"bee.app:status_reader"'), '"bee.application:status_surface"', '"bee.app:status_surface"'), '"bee.application:interaction"', '"bee.app:interaction"'), '"bee.application:appearance"', '"bee.app:appearance"'), '"bee.application:frame"', '"bee.app:frame"'), '"bee.application:names"', '"bee.app:names"'), '"bee.application:thread_protocol"', '"bee.app:thread_protocol"'), '"bee.application:viz"', '"bee.app:viz"'), '"bee.application:forms"', '"bee.app:forms"'), '"bee.application:diagram"', '"bee.app:diagram"'), '"bee.application:runtime"', '"bee.app:runtime"') WHERE instr(active_json, 'bee.application:') > 0;
UPDATE bee_gateway_access_grants SET traits_json = replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(traits_json, '"bee.application:definition"', '"bee.app:definition"'), '"bee.application:dependency_threads"', '"bee.app:dependency_threads"'), '"bee.application:client"', '"bee.app:client"'), '"bee.application:sessions_protocol"', '"bee.app:sessions_protocol"'), '"bee.application:sessions"', '"bee.app:sessions"'), '"bee.application:arguments"', '"bee.app:arguments"'), '"bee.application:text"', '"bee.app:text"'), '"bee.application:caller"', '"bee.app:caller"'), '"bee.application:folder_picker"', '"bee.app:folder_picker"'), '"bee.application:agent_protocol"', '"bee.app:agent_protocol"'), '"bee.application:host_leases"', '"bee.app:host_leases"'), '"bee.application:status_reader"', '"bee.app:status_reader"'), '"bee.application:status_surface"', '"bee.app:status_surface"'), '"bee.application:interaction"', '"bee.app:interaction"'), '"bee.application:appearance"', '"bee.app:appearance"'), '"bee.application:frame"', '"bee.app:frame"'), '"bee.application:names"', '"bee.app:names"'), '"bee.application:thread_protocol"', '"bee.app:thread_protocol"'), '"bee.application:viz"', '"bee.app:viz"'), '"bee.application:forms"', '"bee.app:forms"'), '"bee.application:diagram"', '"bee.app:diagram"'), '"bee.application:runtime"', '"bee.app:runtime"') WHERE instr(traits_json, 'bee.application:') > 0;
]]
local LAYOUT_REFERENCES_SQL = [[
UPDATE bee_gateway_surfaces SET surface_json = (
  WITH RECURSIVE identity_moves(position, prior, current) AS (VALUES
    (1, '"bee.driver.wippy:run"', '"bee.driver.wippy.binding:run"'),
    (2, '"bee.gateway:address"', '"bee.gateway.binding:address"'),
    (3, '"bee.git.worktree:cleanup"', '"bee.git.worktree.binding:cleanup"'),
    (4, '"bee.git.worktree:plan"', '"bee.git.worktree.binding:plan"'),
    (5, '"bee.git.worktree:setup"', '"bee.git.worktree.binding:setup"'),
    (6, '"bee.git_worktree"', '"bee.git.worktree"'),
    (7, '"bee.git_worktree:binding"', '"bee.git.worktree:binding"'),
    (8, '"bee.git_worktree:cleanup"', '"bee.git.worktree.binding:cleanup"'),
    (9, '"bee.git_worktree:definition"', '"bee.git.worktree:definition"'),
    (10, '"bee.git_worktree:dependency_driver"', '"bee.git.worktree:dependency_driver"'),
    (11, '"bee.git_worktree:dependency_placement"', '"bee.git.worktree:dependency_placement"'),
    (12, '"bee.git_worktree:dependency_threads"', '"bee.git.worktree:dependency_threads"'),
    (13, '"bee.git_worktree:executor_ref"', '"bee.git.worktree:executor_ref"'),
    (14, '"bee.git_worktree:git_executor"', '"bee.git.worktree:git_executor"'),
    (15, '"bee.git_worktree:git_roots"', '"bee.git.worktree:git_roots"'),
    (16, '"bee.git_worktree:host_files"', '"bee.git.worktree:host_files"'),
    (17, '"bee.git_worktree:host_files_ref"', '"bee.git.worktree:host_files_ref"'),
    (18, '"bee.git_worktree:plan"', '"bee.git.worktree.binding:plan"'),
    (19, '"bee.git_worktree:protected_namespace"', '"bee.git.worktree:protected_namespace"'),
    (20, '"bee.git_worktree:setup"', '"bee.git.worktree.binding:setup"'),
    (21, '"bee.git_worktree:target_executor"', '"bee.git.worktree:target_executor"'),
    (22, '"bee.git_worktree:target_host_files"', '"bee.git.worktree:target_host_files"'),
    (23, '"bee.git_worktree:worktree"', '"bee.git.worktree:worktree"'),
    (24, '"bee.git_worktree:worktree_policy"', '"bee.git.worktree:worktree_policy"'),
    (25, '"bee.harness.carrier:capabilities"', '"bee.harness.binding:capabilities"'),
    (26, '"bee.harness.carrier:process"', '"bee.harness.service:carrier"'),
    (27, '"bee.harness.carrier:types"', '"bee.harness:types"'),
    (28, '"bee.harness.launch:admit"', '"bee.harness.binding:admit"'),
    (29, '"bee.harness.launch:locate_probe"', '"bee.harness.binding:locate_probe"'),
    (30, '"bee.harness.launch:present"', '"bee.harness.binding:present"'),
    (31, '"bee.harness.launch:resolve"', '"bee.harness.binding:resolve"'),
    (32, '"bee.harness.launch:setup"', '"bee.harness.binding:setup"'),
    (33, '"bee.harness.launch:setup_backend"', '"bee.harness.binding:setup_backend"'),
    (34, '"bee.harness.launch:start"', '"bee.harness.binding:start"'),
    (35, '"bee.harness.profiles:call"', '"bee.harness.binding:call"'),
    (36, '"bee.harness.profiles:contract"', '"bee.harness:profiles"'),
    (37, '"bee.harness.profiles:local"', '"bee.harness:profiles_local"'),
    (38, '"bee.hive.telemetry:catalog_list"', '"bee.hive.telemetry.binding:catalog_list"'),
    (39, '"bee.hive.telemetry:cluster"', '"bee.hive.telemetry.binding:cluster"'),
    (40, '"bee.hive.telemetry:holdings"', '"bee.hive.telemetry.binding:holdings"'),
    (41, '"bee.hive.telemetry:presence"', '"bee.hive.telemetry.binding:presence"'),
    (42, '"bee.hive.telemetry:stats"', '"bee.hive.telemetry.binding:stats"'),
    (43, '"bee.hive:invoke_check"', '"bee.hive.binding:invoke_check"'),
    (44, '"bee.placement.native:process_runner"', '"bee.placement.native.service:process_runner"'),
    (45, '"bee.sync.hive:admit"', '"bee.sync.binding:admit"'),
    (46, '"bee.threads.approvals:append"', '"bee.threads.binding:append"'),
    (47, '"bee.threads.carrier:cancel_intent"', '"bee.threads.binding:cancel_intent"'),
    (48, '"bee.threads.carrier:cancel_status"', '"bee.threads.binding:cancel_status"'),
    (49, '"bee.threads.carrier:checkpoint"', '"bee.threads.binding:checkpoint"'),
    (50, '"bee.threads.carrier:claim"', '"bee.threads.binding:claim"'),
    (51, '"bee.threads.carrier:commit"', '"bee.threads.binding:commit"'),
    (52, '"bee.threads.delivery:ack"', '"bee.threads.binding:ack"'),
    (53, '"bee.threads.delivery:ack_page"', '"bee.threads.binding:ack_page"'),
    (54, '"bee.threads.delivery:claim"', '"bee.threads.binding:delivery_claim"'),
    (55, '"bee.threads.delivery:close_subscription"', '"bee.threads.binding:close_subscription"'),
    (56, '"bee.threads.delivery:dispatch"', '"bee.threads.binding:dispatch"'),
    (57, '"bee.threads.delivery:expire"', '"bee.threads.binding:expire"'),
    (58, '"bee.threads.delivery:forget_subscription"', '"bee.threads.binding:forget_subscription"'),
    (59, '"bee.threads.delivery:page"', '"bee.threads.binding:page"'),
    (60, '"bee.threads.delivery:reconcile"', '"bee.threads.binding:reconcile"'),
    (61, '"bee.threads.delivery:release"', '"bee.threads.binding:release"'),
    (62, '"bee.threads.delivery:resume"', '"bee.threads.binding:resume"'),
    (63, '"bee.threads.delivery:subscribe"', '"bee.threads.binding:subscribe"'),
    (64, '"bee.threads.delivery:unsubscribe"', '"bee.threads.binding:unsubscribe"'),
    (65, '"bee.threads.delivery:wait"', '"bee.threads.binding:wait"'),
    (66, '"bee.threads.delivery:waiter"', '"bee.threads.service:waiter"'),
    (67, '"bee.threads.delivery:waiter_service"', '"bee.threads.service:waiter_service"'),
    (68, '"bee.threads.delivery:watch"', '"bee.threads.binding:watch"'),
    (69, '"bee.threads.projection:recap_read"', '"bee.threads.binding:recap_read"'),
    (70, '"bee.threads.projection:recap_rebuild"', '"bee.threads.binding:recap_rebuild"'),
    (71, '"bee.threads.projection:recap_update"', '"bee.threads.binding:recap_update"'),
    (72, '"bee.threads.projection:status_read"', '"bee.threads.binding:status_read"'),
    (73, '"bee.threads.projection:status_rebuild"', '"bee.threads.binding:status_rebuild"'),
    (74, '"bee.threads.projection:status_update"', '"bee.threads.binding:status_update"'),
    (75, '"bee.threads.records:types"', '"bee.threads:record_types"'),
    (76, '"bee.threads.service:admit_action"', '"bee.threads.binding:admit_action"'),
    (77, '"bee.threads.service:close"', '"bee.threads.binding:close"'),
    (78, '"bee.threads.service:create"', '"bee.threads.binding:create"'),
    (79, '"bee.threads.service:end_turn"', '"bee.threads.binding:end_turn"'),
    (80, '"bee.threads.service:feed_read"', '"bee.threads.binding:feed_read"'),
    (81, '"bee.threads.service:fence_app"', '"bee.threads.binding:fence_app"'),
    (82, '"bee.threads.service:get"', '"bee.threads.binding:get"'),
    (83, '"bee.threads.service:inbox_accept"', '"bee.threads.binding:inbox_accept"'),
    (84, '"bee.threads.service:inbox_ack"', '"bee.threads.binding:inbox_ack"'),
    (85, '"bee.threads.service:inbox_describe"', '"bee.threads.binding:inbox_describe"'),
    (86, '"bee.threads.service:inbox_list"', '"bee.threads.binding:inbox_list"'),
    (87, '"bee.threads.service:inbox_offer"', '"bee.threads.binding:inbox_offer"'),
    (88, '"bee.threads.service:inbox_outbox_claim"', '"bee.threads.binding:inbox_outbox_claim"'),
    (89, '"bee.threads.service:inbox_outbox_settle"', '"bee.threads.binding:inbox_outbox_settle"'),
    (90, '"bee.threads.service:inbox_reply"', '"bee.threads.binding:inbox_reply"'),
    (91, '"bee.threads.service:inbox_resolve"', '"bee.threads.binding:inbox_resolve"'),
    (92, '"bee.threads.service:inbox_send"', '"bee.threads.binding:inbox_send"'),
    (93, '"bee.threads.service:inbox_transport"', '"bee.threads.binding:inbox_transport"'),
    (94, '"bee.threads.service:join"', '"bee.threads.binding:join"'),
    (95, '"bee.threads.service:leave"', '"bee.threads.binding:leave"'),
    (96, '"bee.threads.service:list"', '"bee.threads.binding:list"'),
    (97, '"bee.threads.service:list_workspace"', '"bee.threads.binding:list_workspace"'),
    (98, '"bee.threads.service:notify"', '"bee.threads.binding:notify"'),
    (99, '"bee.threads.service:operation_describe"', '"bee.threads.binding:operation_describe"'),
    (100, '"bee.threads.service:operation_lookup"', '"bee.threads.binding:operation_lookup"'),
    (101, '"bee.threads.service:prepare_attempt"', '"bee.threads.binding:prepare_attempt"'),
    (102, '"bee.threads.service:read_after"', '"bee.threads.binding:read_after"'),
    (103, '"bee.threads.service:receipt"', '"bee.threads.binding:receipt"'),
    (104, '"bee.threads.service:record"', '"bee.threads.binding:record"'),
    (105, '"bee.threads.service:register_app_alias"', '"bee.threads.binding:register_app_alias"'),
    (106, '"bee.threads.service:request_turn"', '"bee.threads.binding:request_turn"'),
    (107, '"bee.threads.service:retire_app_alias"', '"bee.threads.binding:retire_app_alias"'),
    (108, '"bee.threads.service:send"', '"bee.threads.binding:send"'),
    (109, '"bee.threads.service:send_status"', '"bee.threads.binding:send_status"'),
    (110, '"bee.threads.service:session_attach"', '"bee.threads.binding:session_attach"'),
    (111, '"bee.threads.service:session_create"', '"bee.threads.binding:session_create"'),
    (112, '"bee.threads.service:session_describe"', '"bee.threads.binding:session_describe"'),
    (113, '"bee.threads.service:session_scan"', '"bee.threads.binding:session_scan"'),
    (114, '"bee.threads.service:session_transition"', '"bee.threads.binding:session_transition"'),
    (115, '"bee.threads.service:start_attempt"', '"bee.threads.binding:start_attempt"'),
    (116, '"bee.threads.service:turn_accept"', '"bee.threads.binding:turn_accept"'),
    (117, '"bee.threads.service:turn_observation"', '"bee.threads.binding:turn_observation"'),
    (118, '"bee.threads.service:turn_pull"', '"bee.threads.binding:turn_pull"'),
    (119, '"bee.threads.service:turn_recover"', '"bee.threads.binding:turn_recover"'),
    (120, '"bee.threads.service:turn_reserve"', '"bee.threads.binding:turn_reserve"'),
    (121, '"bee.threads.service:types"', '"bee.threads:types"'),
    (122, '"bee.threads.service:work_cancel"', '"bee.threads.binding:work_cancel"'),
    (123, '"bee.threads.service:work_describe"', '"bee.threads.binding:work_describe"'),
    (124, '"bee.threads.service:work_history"', '"bee.threads.binding:work_history"'),
    (125, '"bee.threads.service:work_scan"', '"bee.threads.binding:work_scan"'),
    (126, '"bee.threads.service:work_send"', '"bee.threads.binding:work_send"'),
    (127, '"bee.threads.service:work_settle"', '"bee.threads.binding:work_settle"'),
    (128, '"bee.threads.service:work_uncertain"', '"bee.threads.binding:work_uncertain"'),
    (129, '"bee.threads:capabilities"', '"bee.threads.binding:capabilities"'),
    (130, '"bee.threads:owner"', '"bee.threads.service:owner"'),
    (131, '"bee.threads:owner_service"', '"bee.threads.service:owner_service"')),
  rewritten(position, value) AS (
    SELECT 0, surface_json
    UNION ALL
    SELECT identity_moves.position, replace(rewritten.value, identity_moves.prior, identity_moves.current)
    FROM rewritten JOIN identity_moves ON identity_moves.position = rewritten.position + 1
  )
  SELECT value FROM rewritten ORDER BY position DESC LIMIT 1
) WHERE json_valid(surface_json) AND (instr(surface_json, 'bee.driver.wippy') > 0 OR instr(surface_json, 'bee.gateway') > 0 OR instr(surface_json, 'bee.git.worktree') > 0 OR instr(surface_json, 'bee.git_worktree') > 0 OR instr(surface_json, 'bee.harness.carrier') > 0 OR instr(surface_json, 'bee.harness.launch') > 0 OR instr(surface_json, 'bee.harness.profiles') > 0 OR instr(surface_json, 'bee.hive') > 0 OR instr(surface_json, 'bee.hive.telemetry') > 0 OR instr(surface_json, 'bee.placement.native') > 0 OR instr(surface_json, 'bee.sync.hive') > 0 OR instr(surface_json, 'bee.threads') > 0 OR instr(surface_json, 'bee.threads.approvals') > 0 OR instr(surface_json, 'bee.threads.carrier') > 0 OR instr(surface_json, 'bee.threads.delivery') > 0 OR instr(surface_json, 'bee.threads.projection') > 0 OR instr(surface_json, 'bee.threads.records') > 0 OR instr(surface_json, 'bee.threads.service') > 0);
UPDATE bee_gateway_surfaces SET active_json = (
  WITH RECURSIVE identity_moves(position, prior, current) AS (VALUES
    (1, '"bee.driver.wippy:run"', '"bee.driver.wippy.binding:run"'),
    (2, '"bee.gateway:address"', '"bee.gateway.binding:address"'),
    (3, '"bee.git.worktree:cleanup"', '"bee.git.worktree.binding:cleanup"'),
    (4, '"bee.git.worktree:plan"', '"bee.git.worktree.binding:plan"'),
    (5, '"bee.git.worktree:setup"', '"bee.git.worktree.binding:setup"'),
    (6, '"bee.git_worktree"', '"bee.git.worktree"'),
    (7, '"bee.git_worktree:binding"', '"bee.git.worktree:binding"'),
    (8, '"bee.git_worktree:cleanup"', '"bee.git.worktree.binding:cleanup"'),
    (9, '"bee.git_worktree:definition"', '"bee.git.worktree:definition"'),
    (10, '"bee.git_worktree:dependency_driver"', '"bee.git.worktree:dependency_driver"'),
    (11, '"bee.git_worktree:dependency_placement"', '"bee.git.worktree:dependency_placement"'),
    (12, '"bee.git_worktree:dependency_threads"', '"bee.git.worktree:dependency_threads"'),
    (13, '"bee.git_worktree:executor_ref"', '"bee.git.worktree:executor_ref"'),
    (14, '"bee.git_worktree:git_executor"', '"bee.git.worktree:git_executor"'),
    (15, '"bee.git_worktree:git_roots"', '"bee.git.worktree:git_roots"'),
    (16, '"bee.git_worktree:host_files"', '"bee.git.worktree:host_files"'),
    (17, '"bee.git_worktree:host_files_ref"', '"bee.git.worktree:host_files_ref"'),
    (18, '"bee.git_worktree:plan"', '"bee.git.worktree.binding:plan"'),
    (19, '"bee.git_worktree:protected_namespace"', '"bee.git.worktree:protected_namespace"'),
    (20, '"bee.git_worktree:setup"', '"bee.git.worktree.binding:setup"'),
    (21, '"bee.git_worktree:target_executor"', '"bee.git.worktree:target_executor"'),
    (22, '"bee.git_worktree:target_host_files"', '"bee.git.worktree:target_host_files"'),
    (23, '"bee.git_worktree:worktree"', '"bee.git.worktree:worktree"'),
    (24, '"bee.git_worktree:worktree_policy"', '"bee.git.worktree:worktree_policy"'),
    (25, '"bee.harness.carrier:capabilities"', '"bee.harness.binding:capabilities"'),
    (26, '"bee.harness.carrier:process"', '"bee.harness.service:carrier"'),
    (27, '"bee.harness.carrier:types"', '"bee.harness:types"'),
    (28, '"bee.harness.launch:admit"', '"bee.harness.binding:admit"'),
    (29, '"bee.harness.launch:locate_probe"', '"bee.harness.binding:locate_probe"'),
    (30, '"bee.harness.launch:present"', '"bee.harness.binding:present"'),
    (31, '"bee.harness.launch:resolve"', '"bee.harness.binding:resolve"'),
    (32, '"bee.harness.launch:setup"', '"bee.harness.binding:setup"'),
    (33, '"bee.harness.launch:setup_backend"', '"bee.harness.binding:setup_backend"'),
    (34, '"bee.harness.launch:start"', '"bee.harness.binding:start"'),
    (35, '"bee.harness.profiles:call"', '"bee.harness.binding:call"'),
    (36, '"bee.harness.profiles:contract"', '"bee.harness:profiles"'),
    (37, '"bee.harness.profiles:local"', '"bee.harness:profiles_local"'),
    (38, '"bee.hive.telemetry:catalog_list"', '"bee.hive.telemetry.binding:catalog_list"'),
    (39, '"bee.hive.telemetry:cluster"', '"bee.hive.telemetry.binding:cluster"'),
    (40, '"bee.hive.telemetry:holdings"', '"bee.hive.telemetry.binding:holdings"'),
    (41, '"bee.hive.telemetry:presence"', '"bee.hive.telemetry.binding:presence"'),
    (42, '"bee.hive.telemetry:stats"', '"bee.hive.telemetry.binding:stats"'),
    (43, '"bee.hive:invoke_check"', '"bee.hive.binding:invoke_check"'),
    (44, '"bee.placement.native:process_runner"', '"bee.placement.native.service:process_runner"'),
    (45, '"bee.sync.hive:admit"', '"bee.sync.binding:admit"'),
    (46, '"bee.threads.approvals:append"', '"bee.threads.binding:append"'),
    (47, '"bee.threads.carrier:cancel_intent"', '"bee.threads.binding:cancel_intent"'),
    (48, '"bee.threads.carrier:cancel_status"', '"bee.threads.binding:cancel_status"'),
    (49, '"bee.threads.carrier:checkpoint"', '"bee.threads.binding:checkpoint"'),
    (50, '"bee.threads.carrier:claim"', '"bee.threads.binding:claim"'),
    (51, '"bee.threads.carrier:commit"', '"bee.threads.binding:commit"'),
    (52, '"bee.threads.delivery:ack"', '"bee.threads.binding:ack"'),
    (53, '"bee.threads.delivery:ack_page"', '"bee.threads.binding:ack_page"'),
    (54, '"bee.threads.delivery:claim"', '"bee.threads.binding:delivery_claim"'),
    (55, '"bee.threads.delivery:close_subscription"', '"bee.threads.binding:close_subscription"'),
    (56, '"bee.threads.delivery:dispatch"', '"bee.threads.binding:dispatch"'),
    (57, '"bee.threads.delivery:expire"', '"bee.threads.binding:expire"'),
    (58, '"bee.threads.delivery:forget_subscription"', '"bee.threads.binding:forget_subscription"'),
    (59, '"bee.threads.delivery:page"', '"bee.threads.binding:page"'),
    (60, '"bee.threads.delivery:reconcile"', '"bee.threads.binding:reconcile"'),
    (61, '"bee.threads.delivery:release"', '"bee.threads.binding:release"'),
    (62, '"bee.threads.delivery:resume"', '"bee.threads.binding:resume"'),
    (63, '"bee.threads.delivery:subscribe"', '"bee.threads.binding:subscribe"'),
    (64, '"bee.threads.delivery:unsubscribe"', '"bee.threads.binding:unsubscribe"'),
    (65, '"bee.threads.delivery:wait"', '"bee.threads.binding:wait"'),
    (66, '"bee.threads.delivery:waiter"', '"bee.threads.service:waiter"'),
    (67, '"bee.threads.delivery:waiter_service"', '"bee.threads.service:waiter_service"'),
    (68, '"bee.threads.delivery:watch"', '"bee.threads.binding:watch"'),
    (69, '"bee.threads.projection:recap_read"', '"bee.threads.binding:recap_read"'),
    (70, '"bee.threads.projection:recap_rebuild"', '"bee.threads.binding:recap_rebuild"'),
    (71, '"bee.threads.projection:recap_update"', '"bee.threads.binding:recap_update"'),
    (72, '"bee.threads.projection:status_read"', '"bee.threads.binding:status_read"'),
    (73, '"bee.threads.projection:status_rebuild"', '"bee.threads.binding:status_rebuild"'),
    (74, '"bee.threads.projection:status_update"', '"bee.threads.binding:status_update"'),
    (75, '"bee.threads.records:types"', '"bee.threads:record_types"'),
    (76, '"bee.threads.service:admit_action"', '"bee.threads.binding:admit_action"'),
    (77, '"bee.threads.service:close"', '"bee.threads.binding:close"'),
    (78, '"bee.threads.service:create"', '"bee.threads.binding:create"'),
    (79, '"bee.threads.service:end_turn"', '"bee.threads.binding:end_turn"'),
    (80, '"bee.threads.service:feed_read"', '"bee.threads.binding:feed_read"'),
    (81, '"bee.threads.service:fence_app"', '"bee.threads.binding:fence_app"'),
    (82, '"bee.threads.service:get"', '"bee.threads.binding:get"'),
    (83, '"bee.threads.service:inbox_accept"', '"bee.threads.binding:inbox_accept"'),
    (84, '"bee.threads.service:inbox_ack"', '"bee.threads.binding:inbox_ack"'),
    (85, '"bee.threads.service:inbox_describe"', '"bee.threads.binding:inbox_describe"'),
    (86, '"bee.threads.service:inbox_list"', '"bee.threads.binding:inbox_list"'),
    (87, '"bee.threads.service:inbox_offer"', '"bee.threads.binding:inbox_offer"'),
    (88, '"bee.threads.service:inbox_outbox_claim"', '"bee.threads.binding:inbox_outbox_claim"'),
    (89, '"bee.threads.service:inbox_outbox_settle"', '"bee.threads.binding:inbox_outbox_settle"'),
    (90, '"bee.threads.service:inbox_reply"', '"bee.threads.binding:inbox_reply"'),
    (91, '"bee.threads.service:inbox_resolve"', '"bee.threads.binding:inbox_resolve"'),
    (92, '"bee.threads.service:inbox_send"', '"bee.threads.binding:inbox_send"'),
    (93, '"bee.threads.service:inbox_transport"', '"bee.threads.binding:inbox_transport"'),
    (94, '"bee.threads.service:join"', '"bee.threads.binding:join"'),
    (95, '"bee.threads.service:leave"', '"bee.threads.binding:leave"'),
    (96, '"bee.threads.service:list"', '"bee.threads.binding:list"'),
    (97, '"bee.threads.service:list_workspace"', '"bee.threads.binding:list_workspace"'),
    (98, '"bee.threads.service:notify"', '"bee.threads.binding:notify"'),
    (99, '"bee.threads.service:operation_describe"', '"bee.threads.binding:operation_describe"'),
    (100, '"bee.threads.service:operation_lookup"', '"bee.threads.binding:operation_lookup"'),
    (101, '"bee.threads.service:prepare_attempt"', '"bee.threads.binding:prepare_attempt"'),
    (102, '"bee.threads.service:read_after"', '"bee.threads.binding:read_after"'),
    (103, '"bee.threads.service:receipt"', '"bee.threads.binding:receipt"'),
    (104, '"bee.threads.service:record"', '"bee.threads.binding:record"'),
    (105, '"bee.threads.service:register_app_alias"', '"bee.threads.binding:register_app_alias"'),
    (106, '"bee.threads.service:request_turn"', '"bee.threads.binding:request_turn"'),
    (107, '"bee.threads.service:retire_app_alias"', '"bee.threads.binding:retire_app_alias"'),
    (108, '"bee.threads.service:send"', '"bee.threads.binding:send"'),
    (109, '"bee.threads.service:send_status"', '"bee.threads.binding:send_status"'),
    (110, '"bee.threads.service:session_attach"', '"bee.threads.binding:session_attach"'),
    (111, '"bee.threads.service:session_create"', '"bee.threads.binding:session_create"'),
    (112, '"bee.threads.service:session_describe"', '"bee.threads.binding:session_describe"'),
    (113, '"bee.threads.service:session_scan"', '"bee.threads.binding:session_scan"'),
    (114, '"bee.threads.service:session_transition"', '"bee.threads.binding:session_transition"'),
    (115, '"bee.threads.service:start_attempt"', '"bee.threads.binding:start_attempt"'),
    (116, '"bee.threads.service:turn_accept"', '"bee.threads.binding:turn_accept"'),
    (117, '"bee.threads.service:turn_observation"', '"bee.threads.binding:turn_observation"'),
    (118, '"bee.threads.service:turn_pull"', '"bee.threads.binding:turn_pull"'),
    (119, '"bee.threads.service:turn_recover"', '"bee.threads.binding:turn_recover"'),
    (120, '"bee.threads.service:turn_reserve"', '"bee.threads.binding:turn_reserve"'),
    (121, '"bee.threads.service:types"', '"bee.threads:types"'),
    (122, '"bee.threads.service:work_cancel"', '"bee.threads.binding:work_cancel"'),
    (123, '"bee.threads.service:work_describe"', '"bee.threads.binding:work_describe"'),
    (124, '"bee.threads.service:work_history"', '"bee.threads.binding:work_history"'),
    (125, '"bee.threads.service:work_scan"', '"bee.threads.binding:work_scan"'),
    (126, '"bee.threads.service:work_send"', '"bee.threads.binding:work_send"'),
    (127, '"bee.threads.service:work_settle"', '"bee.threads.binding:work_settle"'),
    (128, '"bee.threads.service:work_uncertain"', '"bee.threads.binding:work_uncertain"'),
    (129, '"bee.threads:capabilities"', '"bee.threads.binding:capabilities"'),
    (130, '"bee.threads:owner"', '"bee.threads.service:owner"'),
    (131, '"bee.threads:owner_service"', '"bee.threads.service:owner_service"')),
  rewritten(position, value) AS (
    SELECT 0, active_json
    UNION ALL
    SELECT identity_moves.position, replace(rewritten.value, identity_moves.prior, identity_moves.current)
    FROM rewritten JOIN identity_moves ON identity_moves.position = rewritten.position + 1
  )
  SELECT value FROM rewritten ORDER BY position DESC LIMIT 1
) WHERE json_valid(active_json) AND (instr(active_json, 'bee.driver.wippy') > 0 OR instr(active_json, 'bee.gateway') > 0 OR instr(active_json, 'bee.git.worktree') > 0 OR instr(active_json, 'bee.git_worktree') > 0 OR instr(active_json, 'bee.harness.carrier') > 0 OR instr(active_json, 'bee.harness.launch') > 0 OR instr(active_json, 'bee.harness.profiles') > 0 OR instr(active_json, 'bee.hive') > 0 OR instr(active_json, 'bee.hive.telemetry') > 0 OR instr(active_json, 'bee.placement.native') > 0 OR instr(active_json, 'bee.sync.hive') > 0 OR instr(active_json, 'bee.threads') > 0 OR instr(active_json, 'bee.threads.approvals') > 0 OR instr(active_json, 'bee.threads.carrier') > 0 OR instr(active_json, 'bee.threads.delivery') > 0 OR instr(active_json, 'bee.threads.projection') > 0 OR instr(active_json, 'bee.threads.records') > 0 OR instr(active_json, 'bee.threads.service') > 0);
UPDATE bee_gateway_access_grants SET traits_json = (
  WITH RECURSIVE identity_moves(position, prior, current) AS (VALUES
    (1, '"bee.driver.wippy:run"', '"bee.driver.wippy.binding:run"'),
    (2, '"bee.gateway:address"', '"bee.gateway.binding:address"'),
    (3, '"bee.git.worktree:cleanup"', '"bee.git.worktree.binding:cleanup"'),
    (4, '"bee.git.worktree:plan"', '"bee.git.worktree.binding:plan"'),
    (5, '"bee.git.worktree:setup"', '"bee.git.worktree.binding:setup"'),
    (6, '"bee.git_worktree"', '"bee.git.worktree"'),
    (7, '"bee.git_worktree:binding"', '"bee.git.worktree:binding"'),
    (8, '"bee.git_worktree:cleanup"', '"bee.git.worktree.binding:cleanup"'),
    (9, '"bee.git_worktree:definition"', '"bee.git.worktree:definition"'),
    (10, '"bee.git_worktree:dependency_driver"', '"bee.git.worktree:dependency_driver"'),
    (11, '"bee.git_worktree:dependency_placement"', '"bee.git.worktree:dependency_placement"'),
    (12, '"bee.git_worktree:dependency_threads"', '"bee.git.worktree:dependency_threads"'),
    (13, '"bee.git_worktree:executor_ref"', '"bee.git.worktree:executor_ref"'),
    (14, '"bee.git_worktree:git_executor"', '"bee.git.worktree:git_executor"'),
    (15, '"bee.git_worktree:git_roots"', '"bee.git.worktree:git_roots"'),
    (16, '"bee.git_worktree:host_files"', '"bee.git.worktree:host_files"'),
    (17, '"bee.git_worktree:host_files_ref"', '"bee.git.worktree:host_files_ref"'),
    (18, '"bee.git_worktree:plan"', '"bee.git.worktree.binding:plan"'),
    (19, '"bee.git_worktree:protected_namespace"', '"bee.git.worktree:protected_namespace"'),
    (20, '"bee.git_worktree:setup"', '"bee.git.worktree.binding:setup"'),
    (21, '"bee.git_worktree:target_executor"', '"bee.git.worktree:target_executor"'),
    (22, '"bee.git_worktree:target_host_files"', '"bee.git.worktree:target_host_files"'),
    (23, '"bee.git_worktree:worktree"', '"bee.git.worktree:worktree"'),
    (24, '"bee.git_worktree:worktree_policy"', '"bee.git.worktree:worktree_policy"'),
    (25, '"bee.harness.carrier:capabilities"', '"bee.harness.binding:capabilities"'),
    (26, '"bee.harness.carrier:process"', '"bee.harness.service:carrier"'),
    (27, '"bee.harness.carrier:types"', '"bee.harness:types"'),
    (28, '"bee.harness.launch:admit"', '"bee.harness.binding:admit"'),
    (29, '"bee.harness.launch:locate_probe"', '"bee.harness.binding:locate_probe"'),
    (30, '"bee.harness.launch:present"', '"bee.harness.binding:present"'),
    (31, '"bee.harness.launch:resolve"', '"bee.harness.binding:resolve"'),
    (32, '"bee.harness.launch:setup"', '"bee.harness.binding:setup"'),
    (33, '"bee.harness.launch:setup_backend"', '"bee.harness.binding:setup_backend"'),
    (34, '"bee.harness.launch:start"', '"bee.harness.binding:start"'),
    (35, '"bee.harness.profiles:call"', '"bee.harness.binding:call"'),
    (36, '"bee.harness.profiles:contract"', '"bee.harness:profiles"'),
    (37, '"bee.harness.profiles:local"', '"bee.harness:profiles_local"'),
    (38, '"bee.hive.telemetry:catalog_list"', '"bee.hive.telemetry.binding:catalog_list"'),
    (39, '"bee.hive.telemetry:cluster"', '"bee.hive.telemetry.binding:cluster"'),
    (40, '"bee.hive.telemetry:holdings"', '"bee.hive.telemetry.binding:holdings"'),
    (41, '"bee.hive.telemetry:presence"', '"bee.hive.telemetry.binding:presence"'),
    (42, '"bee.hive.telemetry:stats"', '"bee.hive.telemetry.binding:stats"'),
    (43, '"bee.hive:invoke_check"', '"bee.hive.binding:invoke_check"'),
    (44, '"bee.placement.native:process_runner"', '"bee.placement.native.service:process_runner"'),
    (45, '"bee.sync.hive:admit"', '"bee.sync.binding:admit"'),
    (46, '"bee.threads.approvals:append"', '"bee.threads.binding:append"'),
    (47, '"bee.threads.carrier:cancel_intent"', '"bee.threads.binding:cancel_intent"'),
    (48, '"bee.threads.carrier:cancel_status"', '"bee.threads.binding:cancel_status"'),
    (49, '"bee.threads.carrier:checkpoint"', '"bee.threads.binding:checkpoint"'),
    (50, '"bee.threads.carrier:claim"', '"bee.threads.binding:claim"'),
    (51, '"bee.threads.carrier:commit"', '"bee.threads.binding:commit"'),
    (52, '"bee.threads.delivery:ack"', '"bee.threads.binding:ack"'),
    (53, '"bee.threads.delivery:ack_page"', '"bee.threads.binding:ack_page"'),
    (54, '"bee.threads.delivery:claim"', '"bee.threads.binding:delivery_claim"'),
    (55, '"bee.threads.delivery:close_subscription"', '"bee.threads.binding:close_subscription"'),
    (56, '"bee.threads.delivery:dispatch"', '"bee.threads.binding:dispatch"'),
    (57, '"bee.threads.delivery:expire"', '"bee.threads.binding:expire"'),
    (58, '"bee.threads.delivery:forget_subscription"', '"bee.threads.binding:forget_subscription"'),
    (59, '"bee.threads.delivery:page"', '"bee.threads.binding:page"'),
    (60, '"bee.threads.delivery:reconcile"', '"bee.threads.binding:reconcile"'),
    (61, '"bee.threads.delivery:release"', '"bee.threads.binding:release"'),
    (62, '"bee.threads.delivery:resume"', '"bee.threads.binding:resume"'),
    (63, '"bee.threads.delivery:subscribe"', '"bee.threads.binding:subscribe"'),
    (64, '"bee.threads.delivery:unsubscribe"', '"bee.threads.binding:unsubscribe"'),
    (65, '"bee.threads.delivery:wait"', '"bee.threads.binding:wait"'),
    (66, '"bee.threads.delivery:waiter"', '"bee.threads.service:waiter"'),
    (67, '"bee.threads.delivery:waiter_service"', '"bee.threads.service:waiter_service"'),
    (68, '"bee.threads.delivery:watch"', '"bee.threads.binding:watch"'),
    (69, '"bee.threads.projection:recap_read"', '"bee.threads.binding:recap_read"'),
    (70, '"bee.threads.projection:recap_rebuild"', '"bee.threads.binding:recap_rebuild"'),
    (71, '"bee.threads.projection:recap_update"', '"bee.threads.binding:recap_update"'),
    (72, '"bee.threads.projection:status_read"', '"bee.threads.binding:status_read"'),
    (73, '"bee.threads.projection:status_rebuild"', '"bee.threads.binding:status_rebuild"'),
    (74, '"bee.threads.projection:status_update"', '"bee.threads.binding:status_update"'),
    (75, '"bee.threads.records:types"', '"bee.threads:record_types"'),
    (76, '"bee.threads.service:admit_action"', '"bee.threads.binding:admit_action"'),
    (77, '"bee.threads.service:close"', '"bee.threads.binding:close"'),
    (78, '"bee.threads.service:create"', '"bee.threads.binding:create"'),
    (79, '"bee.threads.service:end_turn"', '"bee.threads.binding:end_turn"'),
    (80, '"bee.threads.service:feed_read"', '"bee.threads.binding:feed_read"'),
    (81, '"bee.threads.service:fence_app"', '"bee.threads.binding:fence_app"'),
    (82, '"bee.threads.service:get"', '"bee.threads.binding:get"'),
    (83, '"bee.threads.service:inbox_accept"', '"bee.threads.binding:inbox_accept"'),
    (84, '"bee.threads.service:inbox_ack"', '"bee.threads.binding:inbox_ack"'),
    (85, '"bee.threads.service:inbox_describe"', '"bee.threads.binding:inbox_describe"'),
    (86, '"bee.threads.service:inbox_list"', '"bee.threads.binding:inbox_list"'),
    (87, '"bee.threads.service:inbox_offer"', '"bee.threads.binding:inbox_offer"'),
    (88, '"bee.threads.service:inbox_outbox_claim"', '"bee.threads.binding:inbox_outbox_claim"'),
    (89, '"bee.threads.service:inbox_outbox_settle"', '"bee.threads.binding:inbox_outbox_settle"'),
    (90, '"bee.threads.service:inbox_reply"', '"bee.threads.binding:inbox_reply"'),
    (91, '"bee.threads.service:inbox_resolve"', '"bee.threads.binding:inbox_resolve"'),
    (92, '"bee.threads.service:inbox_send"', '"bee.threads.binding:inbox_send"'),
    (93, '"bee.threads.service:inbox_transport"', '"bee.threads.binding:inbox_transport"'),
    (94, '"bee.threads.service:join"', '"bee.threads.binding:join"'),
    (95, '"bee.threads.service:leave"', '"bee.threads.binding:leave"'),
    (96, '"bee.threads.service:list"', '"bee.threads.binding:list"'),
    (97, '"bee.threads.service:list_workspace"', '"bee.threads.binding:list_workspace"'),
    (98, '"bee.threads.service:notify"', '"bee.threads.binding:notify"'),
    (99, '"bee.threads.service:operation_describe"', '"bee.threads.binding:operation_describe"'),
    (100, '"bee.threads.service:operation_lookup"', '"bee.threads.binding:operation_lookup"'),
    (101, '"bee.threads.service:prepare_attempt"', '"bee.threads.binding:prepare_attempt"'),
    (102, '"bee.threads.service:read_after"', '"bee.threads.binding:read_after"'),
    (103, '"bee.threads.service:receipt"', '"bee.threads.binding:receipt"'),
    (104, '"bee.threads.service:record"', '"bee.threads.binding:record"'),
    (105, '"bee.threads.service:register_app_alias"', '"bee.threads.binding:register_app_alias"'),
    (106, '"bee.threads.service:request_turn"', '"bee.threads.binding:request_turn"'),
    (107, '"bee.threads.service:retire_app_alias"', '"bee.threads.binding:retire_app_alias"'),
    (108, '"bee.threads.service:send"', '"bee.threads.binding:send"'),
    (109, '"bee.threads.service:send_status"', '"bee.threads.binding:send_status"'),
    (110, '"bee.threads.service:session_attach"', '"bee.threads.binding:session_attach"'),
    (111, '"bee.threads.service:session_create"', '"bee.threads.binding:session_create"'),
    (112, '"bee.threads.service:session_describe"', '"bee.threads.binding:session_describe"'),
    (113, '"bee.threads.service:session_scan"', '"bee.threads.binding:session_scan"'),
    (114, '"bee.threads.service:session_transition"', '"bee.threads.binding:session_transition"'),
    (115, '"bee.threads.service:start_attempt"', '"bee.threads.binding:start_attempt"'),
    (116, '"bee.threads.service:turn_accept"', '"bee.threads.binding:turn_accept"'),
    (117, '"bee.threads.service:turn_observation"', '"bee.threads.binding:turn_observation"'),
    (118, '"bee.threads.service:turn_pull"', '"bee.threads.binding:turn_pull"'),
    (119, '"bee.threads.service:turn_recover"', '"bee.threads.binding:turn_recover"'),
    (120, '"bee.threads.service:turn_reserve"', '"bee.threads.binding:turn_reserve"'),
    (121, '"bee.threads.service:types"', '"bee.threads:types"'),
    (122, '"bee.threads.service:work_cancel"', '"bee.threads.binding:work_cancel"'),
    (123, '"bee.threads.service:work_describe"', '"bee.threads.binding:work_describe"'),
    (124, '"bee.threads.service:work_history"', '"bee.threads.binding:work_history"'),
    (125, '"bee.threads.service:work_scan"', '"bee.threads.binding:work_scan"'),
    (126, '"bee.threads.service:work_send"', '"bee.threads.binding:work_send"'),
    (127, '"bee.threads.service:work_settle"', '"bee.threads.binding:work_settle"'),
    (128, '"bee.threads.service:work_uncertain"', '"bee.threads.binding:work_uncertain"'),
    (129, '"bee.threads:capabilities"', '"bee.threads.binding:capabilities"'),
    (130, '"bee.threads:owner"', '"bee.threads.service:owner"'),
    (131, '"bee.threads:owner_service"', '"bee.threads.service:owner_service"')),
  rewritten(position, value) AS (
    SELECT 0, traits_json
    UNION ALL
    SELECT identity_moves.position, replace(rewritten.value, identity_moves.prior, identity_moves.current)
    FROM rewritten JOIN identity_moves ON identity_moves.position = rewritten.position + 1
  )
  SELECT value FROM rewritten ORDER BY position DESC LIMIT 1
) WHERE json_valid(traits_json) AND (instr(traits_json, 'bee.driver.wippy') > 0 OR instr(traits_json, 'bee.gateway') > 0 OR instr(traits_json, 'bee.git.worktree') > 0 OR instr(traits_json, 'bee.git_worktree') > 0 OR instr(traits_json, 'bee.harness.carrier') > 0 OR instr(traits_json, 'bee.harness.launch') > 0 OR instr(traits_json, 'bee.harness.profiles') > 0 OR instr(traits_json, 'bee.hive') > 0 OR instr(traits_json, 'bee.hive.telemetry') > 0 OR instr(traits_json, 'bee.placement.native') > 0 OR instr(traits_json, 'bee.sync.hive') > 0 OR instr(traits_json, 'bee.threads') > 0 OR instr(traits_json, 'bee.threads.approvals') > 0 OR instr(traits_json, 'bee.threads.carrier') > 0 OR instr(traits_json, 'bee.threads.delivery') > 0 OR instr(traits_json, 'bee.threads.projection') > 0 OR instr(traits_json, 'bee.threads.records') > 0 OR instr(traits_json, 'bee.threads.service') > 0);
UPDATE bee_gateway_surfaces SET surface_json = (
  WITH RECURSIVE owner_paths(position, path) AS (
    SELECT row_number() OVER (ORDER BY leaf.fullkey), leaf.fullkey
    FROM json_tree(surface_json) leaf JOIN json_tree(surface_json) owner ON leaf.parent = owner.id
    WHERE owner.key = 'owner_ref' AND leaf.key = 'service_id'
      AND leaf.value = 'bee.hive.telemetry'
  ), rewritten(position, value) AS (
    SELECT 0, surface_json
    UNION ALL
    SELECT owner_paths.position, json_set(rewritten.value, owner_paths.path, 'bee.hive.telemetry.binding')
    FROM rewritten JOIN owner_paths ON owner_paths.position = rewritten.position + 1
  )
  SELECT value FROM rewritten ORDER BY position DESC LIMIT 1
) WHERE json_valid(surface_json) AND instr(surface_json, 'bee.hive.telemetry') > 0;
UPDATE bee_gateway_surfaces SET active_json = (
  WITH RECURSIVE owner_paths(position, path) AS (
    SELECT row_number() OVER (ORDER BY leaf.fullkey), leaf.fullkey
    FROM json_tree(active_json) leaf JOIN json_tree(active_json) owner ON leaf.parent = owner.id
    WHERE owner.key = 'owner_ref' AND leaf.key = 'service_id'
      AND leaf.value = 'bee.hive.telemetry'
  ), rewritten(position, value) AS (
    SELECT 0, active_json
    UNION ALL
    SELECT owner_paths.position, json_set(rewritten.value, owner_paths.path, 'bee.hive.telemetry.binding')
    FROM rewritten JOIN owner_paths ON owner_paths.position = rewritten.position + 1
  )
  SELECT value FROM rewritten ORDER BY position DESC LIMIT 1
) WHERE json_valid(active_json) AND instr(active_json, 'bee.hive.telemetry') > 0;
UPDATE bee_gateway_access_grants SET traits_json = (
  WITH RECURSIVE owner_paths(position, path) AS (
    SELECT row_number() OVER (ORDER BY leaf.fullkey), leaf.fullkey
    FROM json_tree(traits_json) leaf JOIN json_tree(traits_json) owner ON leaf.parent = owner.id
    WHERE owner.key = 'owner_ref' AND leaf.key = 'service_id'
      AND leaf.value = 'bee.hive.telemetry'
  ), rewritten(position, value) AS (
    SELECT 0, traits_json
    UNION ALL
    SELECT owner_paths.position, json_set(rewritten.value, owner_paths.path, 'bee.hive.telemetry.binding')
    FROM rewritten JOIN owner_paths ON owner_paths.position = rewritten.position + 1
  )
  SELECT value FROM rewritten ORDER BY position DESC LIMIT 1
) WHERE json_valid(traits_json) AND instr(traits_json, 'bee.hive.telemetry') > 0;
]]
local ORIGINAL_SQL_16 = [[
UPDATE bee_gateway_surfaces SET surface_json = (
  WITH RECURSIVE identity_moves(position, prior, current) AS (VALUES
    (1, '"bee.driver.wippy:run"', '"bee.driver.wippy.binding:run"'),
    (2, '"bee.gateway:address"', '"bee.gateway.binding:address"'),
    (3, '"bee.git.worktree:cleanup"', '"bee.git.worktree.binding:cleanup"'),
    (4, '"bee.git.worktree:plan"', '"bee.git.worktree.binding:plan"'),
    (5, '"bee.git.worktree:setup"', '"bee.git.worktree.binding:setup"'),
    (6, '"bee.git_worktree"', '"bee.git.worktree"'),
    (7, '"bee.git_worktree:binding"', '"bee.git.worktree:binding"'),
    (8, '"bee.git_worktree:cleanup"', '"bee.git.worktree.binding:cleanup"'),
    (9, '"bee.git_worktree:definition"', '"bee.git.worktree:definition"'),
    (10, '"bee.git_worktree:dependency_driver"', '"bee.git.worktree:dependency_driver"'),
    (11, '"bee.git_worktree:dependency_placement"', '"bee.git.worktree:dependency_placement"'),
    (12, '"bee.git_worktree:dependency_threads"', '"bee.git.worktree:dependency_threads"'),
    (13, '"bee.git_worktree:executor_ref"', '"bee.git.worktree:executor_ref"'),
    (14, '"bee.git_worktree:git_executor"', '"bee.git.worktree:git_executor"'),
    (15, '"bee.git_worktree:git_roots"', '"bee.git.worktree:git_roots"'),
    (16, '"bee.git_worktree:host_files"', '"bee.git.worktree:host_files"'),
    (17, '"bee.git_worktree:host_files_ref"', '"bee.git.worktree:host_files_ref"'),
    (18, '"bee.git_worktree:plan"', '"bee.git.worktree.binding:plan"'),
    (19, '"bee.git_worktree:protected_namespace"', '"bee.git.worktree:protected_namespace"'),
    (20, '"bee.git_worktree:setup"', '"bee.git.worktree.binding:setup"'),
    (21, '"bee.git_worktree:target_executor"', '"bee.git.worktree:target_executor"'),
    (22, '"bee.git_worktree:target_host_files"', '"bee.git.worktree:target_host_files"'),
    (23, '"bee.git_worktree:worktree"', '"bee.git.worktree:worktree"'),
    (24, '"bee.git_worktree:worktree_policy"', '"bee.git.worktree:worktree_policy"'),
    (25, '"bee.harness.carrier:capabilities"', '"bee.harness.binding:capabilities"'),
    (26, '"bee.harness.carrier:process"', '"bee.harness.service:carrier"'),
    (27, '"bee.harness.carrier:types"', '"bee.harness:types"'),
    (28, '"bee.harness.launch:admit"', '"bee.harness.binding:admit"'),
    (29, '"bee.harness.launch:locate_probe"', '"bee.harness.binding:locate_probe"'),
    (30, '"bee.harness.launch:present"', '"bee.harness.binding:present"'),
    (31, '"bee.harness.launch:resolve"', '"bee.harness.binding:resolve"'),
    (32, '"bee.harness.launch:setup"', '"bee.harness.binding:setup"'),
    (33, '"bee.harness.launch:setup_backend"', '"bee.harness.binding:setup_backend"'),
    (34, '"bee.harness.launch:start"', '"bee.harness.binding:start"'),
    (35, '"bee.harness.profiles:call"', '"bee.harness.binding:call"'),
    (36, '"bee.harness.profiles:contract"', '"bee.harness:profiles"'),
    (37, '"bee.harness.profiles:local"', '"bee.harness:profiles_local"'),
    (38, '"bee.hive.telemetry:catalog_list"', '"bee.hive.telemetry.binding:catalog_list"'),
    (39, '"bee.hive.telemetry:cluster"', '"bee.hive.telemetry.binding:cluster"'),
    (40, '"bee.hive.telemetry:holdings"', '"bee.hive.telemetry.binding:holdings"'),
    (41, '"bee.hive.telemetry:presence"', '"bee.hive.telemetry.binding:presence"'),
    (42, '"bee.hive.telemetry:stats"', '"bee.hive.telemetry.binding:stats"'),
    (43, '"bee.hive:invoke_check"', '"bee.hive.binding:invoke_check"'),
    (44, '"bee.placement.native:process_runner"', '"bee.placement.native.service:process_runner"'),
    (45, '"bee.sync.hive:admit"', '"bee.sync.binding:admit"'),
    (46, '"bee.threads.approvals:append"', '"bee.threads.binding:append"'),
    (47, '"bee.threads.carrier:cancel_intent"', '"bee.threads.binding:cancel_intent"'),
    (48, '"bee.threads.carrier:cancel_status"', '"bee.threads.binding:cancel_status"'),
    (49, '"bee.threads.carrier:checkpoint"', '"bee.threads.binding:checkpoint"'),
    (50, '"bee.threads.carrier:claim"', '"bee.threads.binding:claim"'),
    (51, '"bee.threads.carrier:commit"', '"bee.threads.binding:commit"'),
    (52, '"bee.threads.delivery:ack"', '"bee.threads.binding:ack"'),
    (53, '"bee.threads.delivery:ack_page"', '"bee.threads.binding:ack_page"'),
    (54, '"bee.threads.delivery:claim"', '"bee.threads.binding:delivery_claim"'),
    (55, '"bee.threads.delivery:close_subscription"', '"bee.threads.binding:close_subscription"'),
    (56, '"bee.threads.delivery:dispatch"', '"bee.threads.binding:dispatch"'),
    (57, '"bee.threads.delivery:expire"', '"bee.threads.binding:expire"'),
    (58, '"bee.threads.delivery:forget_subscription"', '"bee.threads.binding:forget_subscription"'),
    (59, '"bee.threads.delivery:page"', '"bee.threads.binding:page"'),
    (60, '"bee.threads.delivery:reconcile"', '"bee.threads.binding:reconcile"'),
    (61, '"bee.threads.delivery:release"', '"bee.threads.binding:release"'),
    (62, '"bee.threads.delivery:resume"', '"bee.threads.binding:resume"'),
    (63, '"bee.threads.delivery:subscribe"', '"bee.threads.binding:subscribe"'),
    (64, '"bee.threads.delivery:unsubscribe"', '"bee.threads.binding:unsubscribe"'),
    (65, '"bee.threads.delivery:wait"', '"bee.threads.binding:wait"'),
    (66, '"bee.threads.delivery:waiter"', '"bee.threads.service:waiter"'),
    (67, '"bee.threads.delivery:waiter_service"', '"bee.threads.service:waiter_service"'),
    (68, '"bee.threads.delivery:watch"', '"bee.threads.binding:watch"'),
    (69, '"bee.threads.projection:recap_read"', '"bee.threads.binding:recap_read"'),
    (70, '"bee.threads.projection:recap_rebuild"', '"bee.threads.binding:recap_rebuild"'),
    (71, '"bee.threads.projection:recap_update"', '"bee.threads.binding:recap_update"'),
    (72, '"bee.threads.projection:status_read"', '"bee.threads.binding:status_read"'),
    (73, '"bee.threads.projection:status_rebuild"', '"bee.threads.binding:status_rebuild"'),
    (74, '"bee.threads.projection:status_update"', '"bee.threads.binding:status_update"'),
    (75, '"bee.threads.records:types"', '"bee.threads:record_types"'),
    (76, '"bee.threads.service:admit_action"', '"bee.threads.binding:admit_action"'),
    (77, '"bee.threads.service:close"', '"bee.threads.binding:close"'),
    (78, '"bee.threads.service:create"', '"bee.threads.binding:create"'),
    (79, '"bee.threads.service:end_turn"', '"bee.threads.binding:end_turn"'),
    (80, '"bee.threads.service:feed_read"', '"bee.threads.binding:feed_read"'),
    (81, '"bee.threads.service:fence_app"', '"bee.threads.binding:fence_app"'),
    (82, '"bee.threads.service:get"', '"bee.threads.binding:get"'),
    (83, '"bee.threads.service:inbox_accept"', '"bee.threads.binding:inbox_accept"'),
    (84, '"bee.threads.service:inbox_ack"', '"bee.threads.binding:inbox_ack"'),
    (85, '"bee.threads.service:inbox_describe"', '"bee.threads.binding:inbox_describe"'),
    (86, '"bee.threads.service:inbox_list"', '"bee.threads.binding:inbox_list"'),
    (87, '"bee.threads.service:inbox_offer"', '"bee.threads.binding:inbox_offer"'),
    (88, '"bee.threads.service:inbox_outbox_claim"', '"bee.threads.binding:inbox_outbox_claim"'),
    (89, '"bee.threads.service:inbox_outbox_settle"', '"bee.threads.binding:inbox_outbox_settle"'),
    (90, '"bee.threads.service:inbox_reply"', '"bee.threads.binding:inbox_reply"'),
    (91, '"bee.threads.service:inbox_resolve"', '"bee.threads.binding:inbox_resolve"'),
    (92, '"bee.threads.service:inbox_send"', '"bee.threads.binding:inbox_send"'),
    (93, '"bee.threads.service:inbox_transport"', '"bee.threads.binding:inbox_transport"'),
    (94, '"bee.threads.service:join"', '"bee.threads.binding:join"'),
    (95, '"bee.threads.service:leave"', '"bee.threads.binding:leave"'),
    (96, '"bee.threads.service:list"', '"bee.threads.binding:list"'),
    (97, '"bee.threads.service:list_workspace"', '"bee.threads.binding:list_workspace"'),
    (98, '"bee.threads.service:notify"', '"bee.threads.binding:notify"'),
    (99, '"bee.threads.service:operation_describe"', '"bee.threads.binding:operation_describe"'),
    (100, '"bee.threads.service:operation_lookup"', '"bee.threads.binding:operation_lookup"'),
    (101, '"bee.threads.service:prepare_attempt"', '"bee.threads.binding:prepare_attempt"'),
    (102, '"bee.threads.service:read_after"', '"bee.threads.binding:read_after"'),
    (103, '"bee.threads.service:receipt"', '"bee.threads.binding:receipt"'),
    (104, '"bee.threads.service:record"', '"bee.threads.binding:record"'),
    (105, '"bee.threads.service:register_app_alias"', '"bee.threads.binding:register_app_alias"'),
    (106, '"bee.threads.service:request_turn"', '"bee.threads.binding:request_turn"'),
    (107, '"bee.threads.service:retire_app_alias"', '"bee.threads.binding:retire_app_alias"'),
    (108, '"bee.threads.service:send"', '"bee.threads.binding:send"'),
    (109, '"bee.threads.service:send_status"', '"bee.threads.binding:send_status"'),
    (110, '"bee.threads.service:session_attach"', '"bee.threads.binding:session_attach"'),
    (111, '"bee.threads.service:session_create"', '"bee.threads.binding:session_create"'),
    (112, '"bee.threads.service:session_describe"', '"bee.threads.binding:session_describe"'),
    (113, '"bee.threads.service:session_scan"', '"bee.threads.binding:session_scan"'),
    (114, '"bee.threads.service:session_transition"', '"bee.threads.binding:session_transition"'),
    (115, '"bee.threads.service:start_attempt"', '"bee.threads.binding:start_attempt"'),
    (116, '"bee.threads.service:turn_accept"', '"bee.threads.binding:turn_accept"'),
    (117, '"bee.threads.service:turn_observation"', '"bee.threads.binding:turn_observation"'),
    (118, '"bee.threads.service:turn_pull"', '"bee.threads.binding:turn_pull"'),
    (119, '"bee.threads.service:turn_recover"', '"bee.threads.binding:turn_recover"'),
    (120, '"bee.threads.service:turn_reserve"', '"bee.threads.binding:turn_reserve"'),
    (121, '"bee.threads.service:types"', '"bee.threads:types"'),
    (122, '"bee.threads.service:work_cancel"', '"bee.threads.binding:work_cancel"'),
    (123, '"bee.threads.service:work_describe"', '"bee.threads.binding:work_describe"'),
    (124, '"bee.threads.service:work_history"', '"bee.threads.binding:work_history"'),
    (125, '"bee.threads.service:work_scan"', '"bee.threads.binding:work_scan"'),
    (126, '"bee.threads.service:work_send"', '"bee.threads.binding:work_send"'),
    (127, '"bee.threads.service:work_settle"', '"bee.threads.binding:work_settle"'),
    (128, '"bee.threads.service:work_uncertain"', '"bee.threads.binding:work_uncertain"'),
    (129, '"bee.threads:capabilities"', '"bee.threads.binding:capabilities"'),
    (130, '"bee.threads:owner"', '"bee.threads.service:owner"'),
    (131, '"bee.threads:owner_service"', '"bee.threads.service:owner_service"')),
  rewritten(position, value) AS (
    SELECT 0, surface_json
    UNION ALL
    SELECT identity_moves.position, replace(rewritten.value, identity_moves.prior, identity_moves.current)
    FROM rewritten JOIN identity_moves ON identity_moves.position = rewritten.position + 1
  )
  SELECT value FROM rewritten ORDER BY position DESC LIMIT 1
) WHERE json_valid(surface_json) AND (instr(surface_json, 'bee.driver.wippy') > 0 OR instr(surface_json, 'bee.gateway') > 0 OR instr(surface_json, 'bee.git.worktree') > 0 OR instr(surface_json, 'bee.git_worktree') > 0 OR instr(surface_json, 'bee.harness.carrier') > 0 OR instr(surface_json, 'bee.harness.launch') > 0 OR instr(surface_json, 'bee.harness.profiles') > 0 OR instr(surface_json, 'bee.hive') > 0 OR instr(surface_json, 'bee.hive.telemetry') > 0 OR instr(surface_json, 'bee.placement.native') > 0 OR instr(surface_json, 'bee.sync.hive') > 0 OR instr(surface_json, 'bee.threads') > 0 OR instr(surface_json, 'bee.threads.approvals') > 0 OR instr(surface_json, 'bee.threads.carrier') > 0 OR instr(surface_json, 'bee.threads.delivery') > 0 OR instr(surface_json, 'bee.threads.projection') > 0 OR instr(surface_json, 'bee.threads.records') > 0 OR instr(surface_json, 'bee.threads.service') > 0);
UPDATE bee_gateway_surfaces SET active_json = (
  WITH RECURSIVE identity_moves(position, prior, current) AS (VALUES
    (1, '"bee.driver.wippy:run"', '"bee.driver.wippy.binding:run"'),
    (2, '"bee.gateway:address"', '"bee.gateway.binding:address"'),
    (3, '"bee.git.worktree:cleanup"', '"bee.git.worktree.binding:cleanup"'),
    (4, '"bee.git.worktree:plan"', '"bee.git.worktree.binding:plan"'),
    (5, '"bee.git.worktree:setup"', '"bee.git.worktree.binding:setup"'),
    (6, '"bee.git_worktree"', '"bee.git.worktree"'),
    (7, '"bee.git_worktree:binding"', '"bee.git.worktree:binding"'),
    (8, '"bee.git_worktree:cleanup"', '"bee.git.worktree.binding:cleanup"'),
    (9, '"bee.git_worktree:definition"', '"bee.git.worktree:definition"'),
    (10, '"bee.git_worktree:dependency_driver"', '"bee.git.worktree:dependency_driver"'),
    (11, '"bee.git_worktree:dependency_placement"', '"bee.git.worktree:dependency_placement"'),
    (12, '"bee.git_worktree:dependency_threads"', '"bee.git.worktree:dependency_threads"'),
    (13, '"bee.git_worktree:executor_ref"', '"bee.git.worktree:executor_ref"'),
    (14, '"bee.git_worktree:git_executor"', '"bee.git.worktree:git_executor"'),
    (15, '"bee.git_worktree:git_roots"', '"bee.git.worktree:git_roots"'),
    (16, '"bee.git_worktree:host_files"', '"bee.git.worktree:host_files"'),
    (17, '"bee.git_worktree:host_files_ref"', '"bee.git.worktree:host_files_ref"'),
    (18, '"bee.git_worktree:plan"', '"bee.git.worktree.binding:plan"'),
    (19, '"bee.git_worktree:protected_namespace"', '"bee.git.worktree:protected_namespace"'),
    (20, '"bee.git_worktree:setup"', '"bee.git.worktree.binding:setup"'),
    (21, '"bee.git_worktree:target_executor"', '"bee.git.worktree:target_executor"'),
    (22, '"bee.git_worktree:target_host_files"', '"bee.git.worktree:target_host_files"'),
    (23, '"bee.git_worktree:worktree"', '"bee.git.worktree:worktree"'),
    (24, '"bee.git_worktree:worktree_policy"', '"bee.git.worktree:worktree_policy"'),
    (25, '"bee.harness.carrier:capabilities"', '"bee.harness.binding:capabilities"'),
    (26, '"bee.harness.carrier:process"', '"bee.harness.service:carrier"'),
    (27, '"bee.harness.carrier:types"', '"bee.harness:types"'),
    (28, '"bee.harness.launch:admit"', '"bee.harness.binding:admit"'),
    (29, '"bee.harness.launch:locate_probe"', '"bee.harness.binding:locate_probe"'),
    (30, '"bee.harness.launch:present"', '"bee.harness.binding:present"'),
    (31, '"bee.harness.launch:resolve"', '"bee.harness.binding:resolve"'),
    (32, '"bee.harness.launch:setup"', '"bee.harness.binding:setup"'),
    (33, '"bee.harness.launch:setup_backend"', '"bee.harness.binding:setup_backend"'),
    (34, '"bee.harness.launch:start"', '"bee.harness.binding:start"'),
    (35, '"bee.harness.profiles:call"', '"bee.harness.binding:call"'),
    (36, '"bee.harness.profiles:contract"', '"bee.harness:profiles"'),
    (37, '"bee.harness.profiles:local"', '"bee.harness:profiles_local"'),
    (38, '"bee.hive.telemetry:catalog_list"', '"bee.hive.telemetry.binding:catalog_list"'),
    (39, '"bee.hive.telemetry:cluster"', '"bee.hive.telemetry.binding:cluster"'),
    (40, '"bee.hive.telemetry:holdings"', '"bee.hive.telemetry.binding:holdings"'),
    (41, '"bee.hive.telemetry:presence"', '"bee.hive.telemetry.binding:presence"'),
    (42, '"bee.hive.telemetry:stats"', '"bee.hive.telemetry.binding:stats"'),
    (43, '"bee.hive:invoke_check"', '"bee.hive.binding:invoke_check"'),
    (44, '"bee.placement.native:process_runner"', '"bee.placement.native.service:process_runner"'),
    (45, '"bee.sync.hive:admit"', '"bee.sync.binding:admit"'),
    (46, '"bee.threads.approvals:append"', '"bee.threads.binding:append"'),
    (47, '"bee.threads.carrier:cancel_intent"', '"bee.threads.binding:cancel_intent"'),
    (48, '"bee.threads.carrier:cancel_status"', '"bee.threads.binding:cancel_status"'),
    (49, '"bee.threads.carrier:checkpoint"', '"bee.threads.binding:checkpoint"'),
    (50, '"bee.threads.carrier:claim"', '"bee.threads.binding:claim"'),
    (51, '"bee.threads.carrier:commit"', '"bee.threads.binding:commit"'),
    (52, '"bee.threads.delivery:ack"', '"bee.threads.binding:ack"'),
    (53, '"bee.threads.delivery:ack_page"', '"bee.threads.binding:ack_page"'),
    (54, '"bee.threads.delivery:claim"', '"bee.threads.binding:delivery_claim"'),
    (55, '"bee.threads.delivery:close_subscription"', '"bee.threads.binding:close_subscription"'),
    (56, '"bee.threads.delivery:dispatch"', '"bee.threads.binding:dispatch"'),
    (57, '"bee.threads.delivery:expire"', '"bee.threads.binding:expire"'),
    (58, '"bee.threads.delivery:forget_subscription"', '"bee.threads.binding:forget_subscription"'),
    (59, '"bee.threads.delivery:page"', '"bee.threads.binding:page"'),
    (60, '"bee.threads.delivery:reconcile"', '"bee.threads.binding:reconcile"'),
    (61, '"bee.threads.delivery:release"', '"bee.threads.binding:release"'),
    (62, '"bee.threads.delivery:resume"', '"bee.threads.binding:resume"'),
    (63, '"bee.threads.delivery:subscribe"', '"bee.threads.binding:subscribe"'),
    (64, '"bee.threads.delivery:unsubscribe"', '"bee.threads.binding:unsubscribe"'),
    (65, '"bee.threads.delivery:wait"', '"bee.threads.binding:wait"'),
    (66, '"bee.threads.delivery:waiter"', '"bee.threads.service:waiter"'),
    (67, '"bee.threads.delivery:waiter_service"', '"bee.threads.service:waiter_service"'),
    (68, '"bee.threads.delivery:watch"', '"bee.threads.binding:watch"'),
    (69, '"bee.threads.projection:recap_read"', '"bee.threads.binding:recap_read"'),
    (70, '"bee.threads.projection:recap_rebuild"', '"bee.threads.binding:recap_rebuild"'),
    (71, '"bee.threads.projection:recap_update"', '"bee.threads.binding:recap_update"'),
    (72, '"bee.threads.projection:status_read"', '"bee.threads.binding:status_read"'),
    (73, '"bee.threads.projection:status_rebuild"', '"bee.threads.binding:status_rebuild"'),
    (74, '"bee.threads.projection:status_update"', '"bee.threads.binding:status_update"'),
    (75, '"bee.threads.records:types"', '"bee.threads:record_types"'),
    (76, '"bee.threads.service:admit_action"', '"bee.threads.binding:admit_action"'),
    (77, '"bee.threads.service:close"', '"bee.threads.binding:close"'),
    (78, '"bee.threads.service:create"', '"bee.threads.binding:create"'),
    (79, '"bee.threads.service:end_turn"', '"bee.threads.binding:end_turn"'),
    (80, '"bee.threads.service:feed_read"', '"bee.threads.binding:feed_read"'),
    (81, '"bee.threads.service:fence_app"', '"bee.threads.binding:fence_app"'),
    (82, '"bee.threads.service:get"', '"bee.threads.binding:get"'),
    (83, '"bee.threads.service:inbox_accept"', '"bee.threads.binding:inbox_accept"'),
    (84, '"bee.threads.service:inbox_ack"', '"bee.threads.binding:inbox_ack"'),
    (85, '"bee.threads.service:inbox_describe"', '"bee.threads.binding:inbox_describe"'),
    (86, '"bee.threads.service:inbox_list"', '"bee.threads.binding:inbox_list"'),
    (87, '"bee.threads.service:inbox_offer"', '"bee.threads.binding:inbox_offer"'),
    (88, '"bee.threads.service:inbox_outbox_claim"', '"bee.threads.binding:inbox_outbox_claim"'),
    (89, '"bee.threads.service:inbox_outbox_settle"', '"bee.threads.binding:inbox_outbox_settle"'),
    (90, '"bee.threads.service:inbox_reply"', '"bee.threads.binding:inbox_reply"'),
    (91, '"bee.threads.service:inbox_resolve"', '"bee.threads.binding:inbox_resolve"'),
    (92, '"bee.threads.service:inbox_send"', '"bee.threads.binding:inbox_send"'),
    (93, '"bee.threads.service:inbox_transport"', '"bee.threads.binding:inbox_transport"'),
    (94, '"bee.threads.service:join"', '"bee.threads.binding:join"'),
    (95, '"bee.threads.service:leave"', '"bee.threads.binding:leave"'),
    (96, '"bee.threads.service:list"', '"bee.threads.binding:list"'),
    (97, '"bee.threads.service:list_workspace"', '"bee.threads.binding:list_workspace"'),
    (98, '"bee.threads.service:notify"', '"bee.threads.binding:notify"'),
    (99, '"bee.threads.service:operation_describe"', '"bee.threads.binding:operation_describe"'),
    (100, '"bee.threads.service:operation_lookup"', '"bee.threads.binding:operation_lookup"'),
    (101, '"bee.threads.service:prepare_attempt"', '"bee.threads.binding:prepare_attempt"'),
    (102, '"bee.threads.service:read_after"', '"bee.threads.binding:read_after"'),
    (103, '"bee.threads.service:receipt"', '"bee.threads.binding:receipt"'),
    (104, '"bee.threads.service:record"', '"bee.threads.binding:record"'),
    (105, '"bee.threads.service:register_app_alias"', '"bee.threads.binding:register_app_alias"'),
    (106, '"bee.threads.service:request_turn"', '"bee.threads.binding:request_turn"'),
    (107, '"bee.threads.service:retire_app_alias"', '"bee.threads.binding:retire_app_alias"'),
    (108, '"bee.threads.service:send"', '"bee.threads.binding:send"'),
    (109, '"bee.threads.service:send_status"', '"bee.threads.binding:send_status"'),
    (110, '"bee.threads.service:session_attach"', '"bee.threads.binding:session_attach"'),
    (111, '"bee.threads.service:session_create"', '"bee.threads.binding:session_create"'),
    (112, '"bee.threads.service:session_describe"', '"bee.threads.binding:session_describe"'),
    (113, '"bee.threads.service:session_scan"', '"bee.threads.binding:session_scan"'),
    (114, '"bee.threads.service:session_transition"', '"bee.threads.binding:session_transition"'),
    (115, '"bee.threads.service:start_attempt"', '"bee.threads.binding:start_attempt"'),
    (116, '"bee.threads.service:turn_accept"', '"bee.threads.binding:turn_accept"'),
    (117, '"bee.threads.service:turn_observation"', '"bee.threads.binding:turn_observation"'),
    (118, '"bee.threads.service:turn_pull"', '"bee.threads.binding:turn_pull"'),
    (119, '"bee.threads.service:turn_recover"', '"bee.threads.binding:turn_recover"'),
    (120, '"bee.threads.service:turn_reserve"', '"bee.threads.binding:turn_reserve"'),
    (121, '"bee.threads.service:types"', '"bee.threads:types"'),
    (122, '"bee.threads.service:work_cancel"', '"bee.threads.binding:work_cancel"'),
    (123, '"bee.threads.service:work_describe"', '"bee.threads.binding:work_describe"'),
    (124, '"bee.threads.service:work_history"', '"bee.threads.binding:work_history"'),
    (125, '"bee.threads.service:work_scan"', '"bee.threads.binding:work_scan"'),
    (126, '"bee.threads.service:work_send"', '"bee.threads.binding:work_send"'),
    (127, '"bee.threads.service:work_settle"', '"bee.threads.binding:work_settle"'),
    (128, '"bee.threads.service:work_uncertain"', '"bee.threads.binding:work_uncertain"'),
    (129, '"bee.threads:capabilities"', '"bee.threads.binding:capabilities"'),
    (130, '"bee.threads:owner"', '"bee.threads.service:owner"'),
    (131, '"bee.threads:owner_service"', '"bee.threads.service:owner_service"')),
  rewritten(position, value) AS (
    SELECT 0, active_json
    UNION ALL
    SELECT identity_moves.position, replace(rewritten.value, identity_moves.prior, identity_moves.current)
    FROM rewritten JOIN identity_moves ON identity_moves.position = rewritten.position + 1
  )
  SELECT value FROM rewritten ORDER BY position DESC LIMIT 1
) WHERE json_valid(active_json) AND (instr(active_json, 'bee.driver.wippy') > 0 OR instr(active_json, 'bee.gateway') > 0 OR instr(active_json, 'bee.git.worktree') > 0 OR instr(active_json, 'bee.git_worktree') > 0 OR instr(active_json, 'bee.harness.carrier') > 0 OR instr(active_json, 'bee.harness.launch') > 0 OR instr(active_json, 'bee.harness.profiles') > 0 OR instr(active_json, 'bee.hive') > 0 OR instr(active_json, 'bee.hive.telemetry') > 0 OR instr(active_json, 'bee.placement.native') > 0 OR instr(active_json, 'bee.sync.hive') > 0 OR instr(active_json, 'bee.threads') > 0 OR instr(active_json, 'bee.threads.approvals') > 0 OR instr(active_json, 'bee.threads.carrier') > 0 OR instr(active_json, 'bee.threads.delivery') > 0 OR instr(active_json, 'bee.threads.projection') > 0 OR instr(active_json, 'bee.threads.records') > 0 OR instr(active_json, 'bee.threads.service') > 0);
UPDATE bee_gateway_access_grants SET traits_json = (
  WITH RECURSIVE identity_moves(position, prior, current) AS (VALUES
    (1, '"bee.driver.wippy:run"', '"bee.driver.wippy.binding:run"'),
    (2, '"bee.gateway:address"', '"bee.gateway.binding:address"'),
    (3, '"bee.git.worktree:cleanup"', '"bee.git.worktree.binding:cleanup"'),
    (4, '"bee.git.worktree:plan"', '"bee.git.worktree.binding:plan"'),
    (5, '"bee.git.worktree:setup"', '"bee.git.worktree.binding:setup"'),
    (6, '"bee.git_worktree"', '"bee.git.worktree"'),
    (7, '"bee.git_worktree:binding"', '"bee.git.worktree:binding"'),
    (8, '"bee.git_worktree:cleanup"', '"bee.git.worktree.binding:cleanup"'),
    (9, '"bee.git_worktree:definition"', '"bee.git.worktree:definition"'),
    (10, '"bee.git_worktree:dependency_driver"', '"bee.git.worktree:dependency_driver"'),
    (11, '"bee.git_worktree:dependency_placement"', '"bee.git.worktree:dependency_placement"'),
    (12, '"bee.git_worktree:dependency_threads"', '"bee.git.worktree:dependency_threads"'),
    (13, '"bee.git_worktree:executor_ref"', '"bee.git.worktree:executor_ref"'),
    (14, '"bee.git_worktree:git_executor"', '"bee.git.worktree:git_executor"'),
    (15, '"bee.git_worktree:git_roots"', '"bee.git.worktree:git_roots"'),
    (16, '"bee.git_worktree:host_files"', '"bee.git.worktree:host_files"'),
    (17, '"bee.git_worktree:host_files_ref"', '"bee.git.worktree:host_files_ref"'),
    (18, '"bee.git_worktree:plan"', '"bee.git.worktree.binding:plan"'),
    (19, '"bee.git_worktree:protected_namespace"', '"bee.git.worktree:protected_namespace"'),
    (20, '"bee.git_worktree:setup"', '"bee.git.worktree.binding:setup"'),
    (21, '"bee.git_worktree:target_executor"', '"bee.git.worktree:target_executor"'),
    (22, '"bee.git_worktree:target_host_files"', '"bee.git.worktree:target_host_files"'),
    (23, '"bee.git_worktree:worktree"', '"bee.git.worktree:worktree"'),
    (24, '"bee.git_worktree:worktree_policy"', '"bee.git.worktree:worktree_policy"'),
    (25, '"bee.harness.carrier:capabilities"', '"bee.harness.binding:capabilities"'),
    (26, '"bee.harness.carrier:process"', '"bee.harness.service:carrier"'),
    (27, '"bee.harness.carrier:types"', '"bee.harness:types"'),
    (28, '"bee.harness.launch:admit"', '"bee.harness.binding:admit"'),
    (29, '"bee.harness.launch:locate_probe"', '"bee.harness.binding:locate_probe"'),
    (30, '"bee.harness.launch:present"', '"bee.harness.binding:present"'),
    (31, '"bee.harness.launch:resolve"', '"bee.harness.binding:resolve"'),
    (32, '"bee.harness.launch:setup"', '"bee.harness.binding:setup"'),
    (33, '"bee.harness.launch:setup_backend"', '"bee.harness.binding:setup_backend"'),
    (34, '"bee.harness.launch:start"', '"bee.harness.binding:start"'),
    (35, '"bee.harness.profiles:call"', '"bee.harness.binding:call"'),
    (36, '"bee.harness.profiles:contract"', '"bee.harness:profiles"'),
    (37, '"bee.harness.profiles:local"', '"bee.harness:profiles_local"'),
    (38, '"bee.hive.telemetry:catalog_list"', '"bee.hive.telemetry.binding:catalog_list"'),
    (39, '"bee.hive.telemetry:cluster"', '"bee.hive.telemetry.binding:cluster"'),
    (40, '"bee.hive.telemetry:holdings"', '"bee.hive.telemetry.binding:holdings"'),
    (41, '"bee.hive.telemetry:presence"', '"bee.hive.telemetry.binding:presence"'),
    (42, '"bee.hive.telemetry:stats"', '"bee.hive.telemetry.binding:stats"'),
    (43, '"bee.hive:invoke_check"', '"bee.hive.binding:invoke_check"'),
    (44, '"bee.placement.native:process_runner"', '"bee.placement.native.service:process_runner"'),
    (45, '"bee.sync.hive:admit"', '"bee.sync.binding:admit"'),
    (46, '"bee.threads.approvals:append"', '"bee.threads.binding:append"'),
    (47, '"bee.threads.carrier:cancel_intent"', '"bee.threads.binding:cancel_intent"'),
    (48, '"bee.threads.carrier:cancel_status"', '"bee.threads.binding:cancel_status"'),
    (49, '"bee.threads.carrier:checkpoint"', '"bee.threads.binding:checkpoint"'),
    (50, '"bee.threads.carrier:claim"', '"bee.threads.binding:claim"'),
    (51, '"bee.threads.carrier:commit"', '"bee.threads.binding:commit"'),
    (52, '"bee.threads.delivery:ack"', '"bee.threads.binding:ack"'),
    (53, '"bee.threads.delivery:ack_page"', '"bee.threads.binding:ack_page"'),
    (54, '"bee.threads.delivery:claim"', '"bee.threads.binding:delivery_claim"'),
    (55, '"bee.threads.delivery:close_subscription"', '"bee.threads.binding:close_subscription"'),
    (56, '"bee.threads.delivery:dispatch"', '"bee.threads.binding:dispatch"'),
    (57, '"bee.threads.delivery:expire"', '"bee.threads.binding:expire"'),
    (58, '"bee.threads.delivery:forget_subscription"', '"bee.threads.binding:forget_subscription"'),
    (59, '"bee.threads.delivery:page"', '"bee.threads.binding:page"'),
    (60, '"bee.threads.delivery:reconcile"', '"bee.threads.binding:reconcile"'),
    (61, '"bee.threads.delivery:release"', '"bee.threads.binding:release"'),
    (62, '"bee.threads.delivery:resume"', '"bee.threads.binding:resume"'),
    (63, '"bee.threads.delivery:subscribe"', '"bee.threads.binding:subscribe"'),
    (64, '"bee.threads.delivery:unsubscribe"', '"bee.threads.binding:unsubscribe"'),
    (65, '"bee.threads.delivery:wait"', '"bee.threads.binding:wait"'),
    (66, '"bee.threads.delivery:waiter"', '"bee.threads.service:waiter"'),
    (67, '"bee.threads.delivery:waiter_service"', '"bee.threads.service:waiter_service"'),
    (68, '"bee.threads.delivery:watch"', '"bee.threads.binding:watch"'),
    (69, '"bee.threads.projection:recap_read"', '"bee.threads.binding:recap_read"'),
    (70, '"bee.threads.projection:recap_rebuild"', '"bee.threads.binding:recap_rebuild"'),
    (71, '"bee.threads.projection:recap_update"', '"bee.threads.binding:recap_update"'),
    (72, '"bee.threads.projection:status_read"', '"bee.threads.binding:status_read"'),
    (73, '"bee.threads.projection:status_rebuild"', '"bee.threads.binding:status_rebuild"'),
    (74, '"bee.threads.projection:status_update"', '"bee.threads.binding:status_update"'),
    (75, '"bee.threads.records:types"', '"bee.threads:record_types"'),
    (76, '"bee.threads.service:admit_action"', '"bee.threads.binding:admit_action"'),
    (77, '"bee.threads.service:close"', '"bee.threads.binding:close"'),
    (78, '"bee.threads.service:create"', '"bee.threads.binding:create"'),
    (79, '"bee.threads.service:end_turn"', '"bee.threads.binding:end_turn"'),
    (80, '"bee.threads.service:feed_read"', '"bee.threads.binding:feed_read"'),
    (81, '"bee.threads.service:fence_app"', '"bee.threads.binding:fence_app"'),
    (82, '"bee.threads.service:get"', '"bee.threads.binding:get"'),
    (83, '"bee.threads.service:inbox_accept"', '"bee.threads.binding:inbox_accept"'),
    (84, '"bee.threads.service:inbox_ack"', '"bee.threads.binding:inbox_ack"'),
    (85, '"bee.threads.service:inbox_describe"', '"bee.threads.binding:inbox_describe"'),
    (86, '"bee.threads.service:inbox_list"', '"bee.threads.binding:inbox_list"'),
    (87, '"bee.threads.service:inbox_offer"', '"bee.threads.binding:inbox_offer"'),
    (88, '"bee.threads.service:inbox_outbox_claim"', '"bee.threads.binding:inbox_outbox_claim"'),
    (89, '"bee.threads.service:inbox_outbox_settle"', '"bee.threads.binding:inbox_outbox_settle"'),
    (90, '"bee.threads.service:inbox_reply"', '"bee.threads.binding:inbox_reply"'),
    (91, '"bee.threads.service:inbox_resolve"', '"bee.threads.binding:inbox_resolve"'),
    (92, '"bee.threads.service:inbox_send"', '"bee.threads.binding:inbox_send"'),
    (93, '"bee.threads.service:inbox_transport"', '"bee.threads.binding:inbox_transport"'),
    (94, '"bee.threads.service:join"', '"bee.threads.binding:join"'),
    (95, '"bee.threads.service:leave"', '"bee.threads.binding:leave"'),
    (96, '"bee.threads.service:list"', '"bee.threads.binding:list"'),
    (97, '"bee.threads.service:list_workspace"', '"bee.threads.binding:list_workspace"'),
    (98, '"bee.threads.service:notify"', '"bee.threads.binding:notify"'),
    (99, '"bee.threads.service:operation_describe"', '"bee.threads.binding:operation_describe"'),
    (100, '"bee.threads.service:operation_lookup"', '"bee.threads.binding:operation_lookup"'),
    (101, '"bee.threads.service:prepare_attempt"', '"bee.threads.binding:prepare_attempt"'),
    (102, '"bee.threads.service:read_after"', '"bee.threads.binding:read_after"'),
    (103, '"bee.threads.service:receipt"', '"bee.threads.binding:receipt"'),
    (104, '"bee.threads.service:record"', '"bee.threads.binding:record"'),
    (105, '"bee.threads.service:register_app_alias"', '"bee.threads.binding:register_app_alias"'),
    (106, '"bee.threads.service:request_turn"', '"bee.threads.binding:request_turn"'),
    (107, '"bee.threads.service:retire_app_alias"', '"bee.threads.binding:retire_app_alias"'),
    (108, '"bee.threads.service:send"', '"bee.threads.binding:send"'),
    (109, '"bee.threads.service:send_status"', '"bee.threads.binding:send_status"'),
    (110, '"bee.threads.service:session_attach"', '"bee.threads.binding:session_attach"'),
    (111, '"bee.threads.service:session_create"', '"bee.threads.binding:session_create"'),
    (112, '"bee.threads.service:session_describe"', '"bee.threads.binding:session_describe"'),
    (113, '"bee.threads.service:session_scan"', '"bee.threads.binding:session_scan"'),
    (114, '"bee.threads.service:session_transition"', '"bee.threads.binding:session_transition"'),
    (115, '"bee.threads.service:start_attempt"', '"bee.threads.binding:start_attempt"'),
    (116, '"bee.threads.service:turn_accept"', '"bee.threads.binding:turn_accept"'),
    (117, '"bee.threads.service:turn_observation"', '"bee.threads.binding:turn_observation"'),
    (118, '"bee.threads.service:turn_pull"', '"bee.threads.binding:turn_pull"'),
    (119, '"bee.threads.service:turn_recover"', '"bee.threads.binding:turn_recover"'),
    (120, '"bee.threads.service:turn_reserve"', '"bee.threads.binding:turn_reserve"'),
    (121, '"bee.threads.service:types"', '"bee.threads:types"'),
    (122, '"bee.threads.service:work_cancel"', '"bee.threads.binding:work_cancel"'),
    (123, '"bee.threads.service:work_describe"', '"bee.threads.binding:work_describe"'),
    (124, '"bee.threads.service:work_history"', '"bee.threads.binding:work_history"'),
    (125, '"bee.threads.service:work_scan"', '"bee.threads.binding:work_scan"'),
    (126, '"bee.threads.service:work_send"', '"bee.threads.binding:work_send"'),
    (127, '"bee.threads.service:work_settle"', '"bee.threads.binding:work_settle"'),
    (128, '"bee.threads.service:work_uncertain"', '"bee.threads.binding:work_uncertain"'),
    (129, '"bee.threads:capabilities"', '"bee.threads.binding:capabilities"'),
    (130, '"bee.threads:owner"', '"bee.threads.service:owner"'),
    (131, '"bee.threads:owner_service"', '"bee.threads.service:owner_service"')),
  rewritten(position, value) AS (
    SELECT 0, traits_json
    UNION ALL
    SELECT identity_moves.position, replace(rewritten.value, identity_moves.prior, identity_moves.current)
    FROM rewritten JOIN identity_moves ON identity_moves.position = rewritten.position + 1
  )
  SELECT value FROM rewritten ORDER BY position DESC LIMIT 1
) WHERE json_valid(traits_json) AND (instr(traits_json, 'bee.driver.wippy') > 0 OR instr(traits_json, 'bee.gateway') > 0 OR instr(traits_json, 'bee.git.worktree') > 0 OR instr(traits_json, 'bee.git_worktree') > 0 OR instr(traits_json, 'bee.harness.carrier') > 0 OR instr(traits_json, 'bee.harness.launch') > 0 OR instr(traits_json, 'bee.harness.profiles') > 0 OR instr(traits_json, 'bee.hive') > 0 OR instr(traits_json, 'bee.hive.telemetry') > 0 OR instr(traits_json, 'bee.placement.native') > 0 OR instr(traits_json, 'bee.sync.hive') > 0 OR instr(traits_json, 'bee.threads') > 0 OR instr(traits_json, 'bee.threads.approvals') > 0 OR instr(traits_json, 'bee.threads.carrier') > 0 OR instr(traits_json, 'bee.threads.delivery') > 0 OR instr(traits_json, 'bee.threads.projection') > 0 OR instr(traits_json, 'bee.threads.records') > 0 OR instr(traits_json, 'bee.threads.service') > 0);
]]

local TELEMETRY_OWNER_REPAIR_SQL = [[
UPDATE bee_gateway_surfaces SET surface_json = (
  WITH RECURSIVE owner_paths(position, path) AS (
    SELECT row_number() OVER (ORDER BY leaf.fullkey), leaf.fullkey
    FROM json_tree(surface_json) leaf JOIN json_tree(surface_json) owner ON leaf.parent = owner.id
    WHERE owner.key = 'owner_ref' AND leaf.key = 'service_id'
      AND leaf.value = 'bee.hive.telemetry'
  ), rewritten(position, value) AS (
    SELECT 0, surface_json
    UNION ALL
    SELECT owner_paths.position, json_set(rewritten.value, owner_paths.path, 'bee.hive.telemetry.binding')
    FROM rewritten JOIN owner_paths ON owner_paths.position = rewritten.position + 1
  )
  SELECT value FROM rewritten ORDER BY position DESC LIMIT 1
) WHERE json_valid(surface_json) AND instr(surface_json, 'bee.hive.telemetry') > 0;
UPDATE bee_gateway_surfaces SET active_json = (
  WITH RECURSIVE owner_paths(position, path) AS (
    SELECT row_number() OVER (ORDER BY leaf.fullkey), leaf.fullkey
    FROM json_tree(active_json) leaf JOIN json_tree(active_json) owner ON leaf.parent = owner.id
    WHERE owner.key = 'owner_ref' AND leaf.key = 'service_id'
      AND leaf.value = 'bee.hive.telemetry'
  ), rewritten(position, value) AS (
    SELECT 0, active_json
    UNION ALL
    SELECT owner_paths.position, json_set(rewritten.value, owner_paths.path, 'bee.hive.telemetry.binding')
    FROM rewritten JOIN owner_paths ON owner_paths.position = rewritten.position + 1
  )
  SELECT value FROM rewritten ORDER BY position DESC LIMIT 1
) WHERE json_valid(active_json) AND instr(active_json, 'bee.hive.telemetry') > 0;
UPDATE bee_gateway_access_grants SET traits_json = (
  WITH RECURSIVE owner_paths(position, path) AS (
    SELECT row_number() OVER (ORDER BY leaf.fullkey), leaf.fullkey
    FROM json_tree(traits_json) leaf JOIN json_tree(traits_json) owner ON leaf.parent = owner.id
    WHERE owner.key = 'owner_ref' AND leaf.key = 'service_id'
      AND leaf.value = 'bee.hive.telemetry'
  ), rewritten(position, value) AS (
    SELECT 0, traits_json
    UNION ALL
    SELECT owner_paths.position, json_set(rewritten.value, owner_paths.path, 'bee.hive.telemetry.binding')
    FROM rewritten JOIN owner_paths ON owner_paths.position = rewritten.position + 1
  )
  SELECT value FROM rewritten ORDER BY position DESC LIMIT 1
) WHERE json_valid(traits_json) AND instr(traits_json, 'bee.hive.telemetry') > 0;
]]

local ROOT_IDENTITY_VALUES = [[    (1, '"bee.approvals.inbox:client"', '"bee.approvals.inbox.app:client"'),
    (2, '"bee.approvals.inbox:client_policy"', '"bee.approvals.inbox.security:client_policy"'),
    (3, '"bee.approvals.inbox:source_config"', '"bee.approvals.inbox.app:source_config"'),
    (4, '"bee.approvals.inbox:sources"', '"bee.approvals.inbox.app:sources"'),
    (5, '"bee.approvals.inbox:workspaces"', '"bee.approvals.inbox.app:workspaces"'),
    (6, '"bee.approvals:database_ref"', '"bee.approvals.env:database_ref"'),
    (7, '"bee.approvals:db"', '"bee.approvals.env:db"'),
    (8, '"bee.approvals:db_path"', '"bee.approvals.env:db_path"'),
    (9, '"bee.approvals:environment"', '"bee.approvals.env:environment"'),
    (10, '"bee.approvals:identity_migration"', '"bee.approvals.migrations:identity_migration"'),
    (11, '"bee.approvals:local"', '"bee.approvals.binding:local"'),
    (12, '"bee.approvals:node_identity_migration_source"', '"bee.approvals.env:node_identity_migration_source"'),
    (13, '"bee.approvals:policies_ref"', '"bee.approvals.env:policies_ref"'),
    (14, '"bee.approvals:resources"', '"bee.approvals.env:resources"'),
    (15, '"bee.approvals:runtime_lease"', '"bee.approvals.service:runtime_lease"'),
    (16, '"bee.approvals:service"', '"bee.approvals.service:service"'),
    (17, '"bee.console:command"', '"bee.console.app:command"'),
    (18, '"bee.console:command_policy"', '"bee.console.security:command_policy"'),
    (19, '"bee.console:environment"', '"bee.console.env:environment"'),
    (20, '"bee.console:executor"', '"bee.console.env:executor"'),
    (21, '"bee.console:executor_policy"', '"bee.console.security:executor_policy"'),
    (22, '"bee.console:home"', '"bee.console.env:home"'),
    (23, '"bee.console:lang"', '"bee.console.env:lang"'),
    (24, '"bee.console:path"', '"bee.console.env:path"'),
    (25, '"bee.console:user"', '"bee.console.env:user"'),
    (26, '"bee.credentials:credential_sources"', '"bee.credentials.env:credential_sources"'),
    (27, '"bee.credentials:database_ref"', '"bee.credentials.env:database_ref"'),
    (28, '"bee.credentials:db"', '"bee.credentials.env:db"'),
    (29, '"bee.credentials:db_path"', '"bee.credentials.env:db_path"'),
    (30, '"bee.credentials:environment"', '"bee.credentials.env:environment"'),
    (31, '"bee.credentials:local"', '"bee.credentials.binding:local"'),
    (32, '"bee.credentials:materializer_ref"', '"bee.credentials.env:materializer_ref"'),
    (33, '"bee.credentials:node_identity_migration_source"', '"bee.credentials.env:node_identity_migration_source"'),
    (34, '"bee.credentials:sources"', '"bee.credentials.env:sources"'),
    (35, '"bee.credentials:sources_ref"', '"bee.credentials.env:sources_ref"'),
    (36, '"bee.docs:corpus"', '"bee.docs.binding:corpus"'),
    (37, '"bee.docs:corpus_ref"', '"bee.docs.env:corpus_ref"'),
    (38, '"bee.docs:resources"', '"bee.docs.env:resources"'),
    (39, '"bee.driver.agy:binding"', '"bee.driver.agy.binding:binding"'),
    (40, '"bee.driver.agy:command"', '"bee.driver.agy.descriptor:command"'),
    (41, '"bee.driver.agy:configuration"', '"bee.driver.agy.binding:configuration"'),
    (42, '"bee.driver.agy:credential_format"', '"bee.driver.agy.credentials:credential_format"'),
    (43, '"bee.driver.agy:default_window"', '"bee.driver.agy.profiles:default_window"'),
    (44, '"bee.driver.agy:executable"', '"bee.driver.agy.env:executable"'),
    (45, '"bee.driver.agy:launch"', '"bee.driver.agy.binding:launch"'),
    (46, '"bee.driver.agy:launch_policy_agy_batch"', '"bee.driver.agy.security:launch_policy_agy_batch"'),
    (47, '"bee.driver.agy:launch_policy_agy_window"', '"bee.driver.agy.security:launch_policy_agy_window"'),
    (48, '"bee.driver.agy:locate"', '"bee.driver.agy.descriptor:locate"'),
    (49, '"bee.driver.agy:profiles"', '"bee.driver.agy.profiles:profiles"'),
    (50, '"bee.driver.agy:protocol"', '"bee.driver.agy.binding:protocol"'),
    (51, '"bee.driver.agy:research_batch"', '"bee.driver.agy.profiles:research_batch"'),
    (52, '"bee.driver.claude:api_key"', '"bee.driver.claude.env:api_key"'),
    (53, '"bee.driver.claude:binding"', '"bee.driver.claude.binding:binding"'),
    (54, '"bee.driver.claude:command"', '"bee.driver.claude.descriptor:command"'),
    (55, '"bee.driver.claude:config_home"', '"bee.driver.claude.env:config_home"'),
    (56, '"bee.driver.claude:credential_format"', '"bee.driver.claude.credentials:credential_format"'),
    (57, '"bee.driver.claude:default_window"', '"bee.driver.claude.profiles:default_window"'),
    (58, '"bee.driver.claude:executable"', '"bee.driver.claude.env:executable"'),
    (59, '"bee.driver.claude:launch"', '"bee.driver.claude.binding:launch"'),
    (60, '"bee.driver.claude:launch_policy_claude_batch"', '"bee.driver.claude.security:launch_policy_claude_batch"'),
    (61, '"bee.driver.claude:launch_policy_claude_window"', '"bee.driver.claude.security:launch_policy_claude_window"'),
    (62, '"bee.driver.claude:locate"', '"bee.driver.claude.descriptor:locate"'),
    (63, '"bee.driver.claude:permission_adapter"', '"bee.driver.claude.permission:permission_adapter"'),
    (64, '"bee.driver.claude:profiles"', '"bee.driver.claude.profiles:profiles"'),
    (65, '"bee.driver.claude:protocol"', '"bee.driver.claude.binding:protocol"'),
    (66, '"bee.driver.claude:research_batch"', '"bee.driver.claude.profiles:research_batch"'),
    (67, '"bee.driver.codex:binding"', '"bee.driver.codex.binding:binding"'),
    (68, '"bee.driver.codex:command"', '"bee.driver.codex.descriptor:command"'),
    (69, '"bee.driver.codex:config_home"', '"bee.driver.codex.env:config_home"'),
    (70, '"bee.driver.codex:configuration"', '"bee.driver.codex.binding:configuration"'),
    (71, '"bee.driver.codex:credential_format"', '"bee.driver.codex.credentials:credential_format"'),
    (72, '"bee.driver.codex:default_provider"', '"bee.driver.codex.descriptor:default_provider"'),
    (73, '"bee.driver.codex:default_window"', '"bee.driver.codex.profiles:default_window"'),
    (74, '"bee.driver.codex:executable"', '"bee.driver.codex.env:executable"'),
    (75, '"bee.driver.codex:launch"', '"bee.driver.codex.binding:launch"'),
    (76, '"bee.driver.codex:launch_policy_codex_batch"', '"bee.driver.codex.security:launch_policy_codex_batch"'),
    (77, '"bee.driver.codex:launch_policy_codex_named_batch"', '"bee.driver.codex.security:launch_policy_codex_named_batch"'),
    (78, '"bee.driver.codex:launch_policy_codex_window"', '"bee.driver.codex.security:launch_policy_codex_window"'),
    (79, '"bee.driver.codex:locate"', '"bee.driver.codex.descriptor:locate"'),
    (80, '"bee.driver.codex:named_batch"', '"bee.driver.codex.profiles:named_batch"'),
    (81, '"bee.driver.codex:profiles"', '"bee.driver.codex.profiles:profiles"'),
    (82, '"bee.driver.codex:protocol"', '"bee.driver.codex.binding:protocol"'),
    (83, '"bee.driver.codex:research_batch"', '"bee.driver.codex.profiles:research_batch"'),
    (84, '"bee.driver.grok:binding"', '"bee.driver.grok.binding:binding"'),
    (85, '"bee.driver.grok:command"', '"bee.driver.grok.descriptor:command"'),
    (86, '"bee.driver.grok:configuration"', '"bee.driver.grok.binding:configuration"'),
    (87, '"bee.driver.grok:credential_format"', '"bee.driver.grok.credentials:credential_format"'),
    (88, '"bee.driver.grok:default_window"', '"bee.driver.grok.profiles:default_window"'),
    (89, '"bee.driver.grok:executable"', '"bee.driver.grok.env:executable"'),
    (90, '"bee.driver.grok:launch"', '"bee.driver.grok.binding:launch"'),
    (91, '"bee.driver.grok:launch_policy_grok_batch"', '"bee.driver.grok.security:launch_policy_grok_batch"'),
    (92, '"bee.driver.grok:launch_policy_grok_window"', '"bee.driver.grok.security:launch_policy_grok_window"'),
    (93, '"bee.driver.grok:locate"', '"bee.driver.grok.descriptor:locate"'),
    (94, '"bee.driver.grok:profiles"', '"bee.driver.grok.profiles:profiles"'),
    (95, '"bee.driver.grok:protocol"', '"bee.driver.grok.binding:protocol"'),
    (96, '"bee.driver.grok:research_batch"', '"bee.driver.grok.profiles:research_batch"'),
    (97, '"bee.driver.muse:binding"', '"bee.driver.muse.binding:binding"'),
    (98, '"bee.driver.muse:command"', '"bee.driver.muse.descriptor:command"'),
    (99, '"bee.driver.muse:configuration"', '"bee.driver.muse.binding:configuration"'),
    (100, '"bee.driver.muse:credential_format"', '"bee.driver.muse.credentials:credential_format"'),
    (101, '"bee.driver.muse:default_window"', '"bee.driver.muse.profiles:default_window"'),
    (102, '"bee.driver.muse:executable"', '"bee.driver.muse.env:executable"'),
    (103, '"bee.driver.muse:launch"', '"bee.driver.muse.binding:launch"'),
    (104, '"bee.driver.muse:launch_policy_muse_batch"', '"bee.driver.muse.security:launch_policy_muse_batch"'),
    (105, '"bee.driver.muse:launch_policy_muse_window"', '"bee.driver.muse.security:launch_policy_muse_window"'),
    (106, '"bee.driver.muse:locate"', '"bee.driver.muse.descriptor:locate"'),
    (107, '"bee.driver.muse:profiles"', '"bee.driver.muse.profiles:profiles"'),
    (108, '"bee.driver.muse:protocol"', '"bee.driver.muse.binding:protocol"'),
    (109, '"bee.driver.muse:research_batch"', '"bee.driver.muse.profiles:research_batch"'),
    (110, '"bee.driver.opencode:binding"', '"bee.driver.opencode.binding:binding"'),
    (111, '"bee.driver.opencode:command"', '"bee.driver.opencode.descriptor:command"'),
    (112, '"bee.driver.opencode:configuration"', '"bee.driver.opencode.binding:configuration"'),
    (113, '"bee.driver.opencode:credential_format"', '"bee.driver.opencode.credentials:credential_format"'),
    (114, '"bee.driver.opencode:default_window"', '"bee.driver.opencode.profiles:default_window"'),
    (115, '"bee.driver.opencode:executable"', '"bee.driver.opencode.env:executable"'),
    (116, '"bee.driver.opencode:launch"', '"bee.driver.opencode.binding:launch"'),
    (117, '"bee.driver.opencode:launch_policy_opencode_batch"', '"bee.driver.opencode.security:launch_policy_opencode_batch"'),
    (118, '"bee.driver.opencode:launch_policy_opencode_window"', '"bee.driver.opencode.security:launch_policy_opencode_window"'),
    (119, '"bee.driver.opencode:locate"', '"bee.driver.opencode.descriptor:locate"'),
    (120, '"bee.driver.opencode:profiles"', '"bee.driver.opencode.profiles:profiles"'),
    (121, '"bee.driver.opencode:protocol"', '"bee.driver.opencode.binding:protocol"'),
    (122, '"bee.driver.opencode:research_batch"', '"bee.driver.opencode.profiles:research_batch"'),
    (123, '"bee.driver.wippy:binding"', '"bee.driver.wippy.binding:binding"'),
    (124, '"bee.driver.wippy:client"', '"bee.driver.wippy.binding:client"'),
    (125, '"bee.driver.wippy:host_config"', '"bee.driver.wippy.env:host_config"'),
    (126, '"bee.driver.wippy:profiles"', '"bee.driver.wippy.profiles:profiles"'),
    (127, '"bee.driver.wippy:run"', '"bee.driver.wippy.binding:run"'),
    (128, '"bee.driver.wippy:runner"', '"bee.driver.wippy.service:runner"'),
    (129, '"bee.driver:codec_registry"', '"bee.driver.codec:codec_registry"'),
    (130, '"bee.driver:configuration"', '"bee.driver.configuration:configuration"'),
    (131, '"bee.driver:descriptor"', '"bee.driver.descriptor:descriptor"'),
    (132, '"bee.driver:instructions"', '"bee.driver.profiles:instructions"'),
    (133, '"bee.driver:locate"', '"bee.driver.locate:locate"'),
    (134, '"bee.driver:login_evidence"', '"bee.driver.locate:login_evidence"'),
    (135, '"bee.driver:option_render"', '"bee.driver.configuration:option_render"'),
    (136, '"bee.driver:permission_request_hook"', '"bee.driver.permission:permission_request_hook"'),
    (137, '"bee.driver:preferences"', '"bee.driver.profiles:preferences"'),
    (138, '"bee.driver:probe_capture"', '"bee.driver.locate:probe_capture"'),
    (139, '"bee.driver:profile"', '"bee.driver.profiles:profile"'),
    (140, '"bee.driver:profile_access"', '"bee.driver.profiles:profile_access"'),
    (141, '"bee.driver:resolver"', '"bee.driver.binding:resolver"'),
    (142, '"bee.driver:schema_values"', '"bee.driver.descriptor:schema_values"'),
    (143, '"bee.driver:universal"', '"bee.driver.binding:universal"'),
    (144, '"bee.files:gitignore"', '"bee.files.app:gitignore"'),
    (145, '"bee.files:source"', '"bee.files.app:source"'),
    (146, '"bee.files:syntax"', '"bee.files.app:syntax"'),
    (147, '"bee.files:tree"', '"bee.files.app:tree"'),
    (148, '"bee.files:workspace_root_ref"', '"bee.files.env:workspace_root_ref"'),
    (149, '"bee.gateway:address"', '"bee.gateway.binding:address"'),
    (150, '"bee.gateway:address_value"', '"bee.gateway.api:address_value"'),
    (151, '"bee.gateway:approval_consume_policy_ref"', '"bee.gateway.env:approval_consume_policy_ref"'),
    (152, '"bee.gateway:approval_request_policy_ref"', '"bee.gateway.env:approval_request_policy_ref"'),
    (153, '"bee.gateway:catalog"', '"bee.gateway.catalog:catalog"'),
    (154, '"bee.gateway:configuration"', '"bee.gateway.env:configuration"'),
    (155, '"bee.gateway:context"', '"bee.gateway.catalog:context"'),
    (156, '"bee.gateway:database_ref"', '"bee.gateway.env:database_ref"'),
    (157, '"bee.gateway:db"', '"bee.gateway.env:db"'),
    (158, '"bee.gateway:db_path"', '"bee.gateway.env:db_path"'),
    (159, '"bee.gateway:endpoint_ref"', '"bee.gateway.env:endpoint_ref"'),
    (160, '"bee.gateway:environment"', '"bee.gateway.env:environment"'),
    (161, '"bee.gateway:hook_executable"', '"bee.gateway.env:hook_executable"'),
    (162, '"bee.gateway:hooks"', '"bee.gateway.hooks:hooks"'),
    (163, '"bee.gateway:install_configuration_ref"', '"bee.gateway.env:install_configuration_ref"'),
    (164, '"bee.gateway:json_schema"', '"bee.gateway.catalog:json_schema"'),
    (165, '"bee.gateway:listener_ref"', '"bee.gateway.env:listener_ref"'),
    (166, '"bee.gateway:mcp"', '"bee.gateway.api:mcp"'),
    (167, '"bee.gateway:profile_scope"', '"bee.gateway.catalog:profile_scope"'),
    (168, '"bee.gateway:publish_configuration_ref"', '"bee.gateway.env:publish_configuration_ref"'),
    (169, '"bee.gateway:session_bundle"', '"bee.gateway.catalog:session_bundle"'),
    (170, '"bee.gateway:session_tools"', '"bee.gateway.catalog:session_tools"'),
    (171, '"bee.gateway:sessions"', '"bee.gateway.catalog:sessions"'),
    (172, '"bee.gateway:surface"', '"bee.gateway.catalog:surface"'),
    (173, '"bee.gateway:tool_application_open_policy_ref"', '"bee.gateway.env:tool_application_open_policy_ref"'),
    (174, '"bee.gateway:tool_components_policy_ref"', '"bee.gateway.env:tool_components_policy_ref"'),
    (175, '"bee.gateway:tool_delivery_policy_ref"', '"bee.gateway.env:tool_delivery_policy_ref"'),
    (176, '"bee.gateway:tool_docs_policy_ref"', '"bee.gateway.env:tool_docs_policy_ref"'),
    (177, '"bee.gateway:tool_hub_publish_policy_ref"', '"bee.gateway.env:tool_hub_publish_policy_ref"'),
    (178, '"bee.gateway:tool_install_policy_ref"', '"bee.gateway.env:tool_install_policy_ref"'),
    (179, '"bee.gateway:tool_message_policy_ref"', '"bee.gateway.env:tool_message_policy_ref"'),
    (180, '"bee.gateway:tool_overlay_policy_ref"', '"bee.gateway.env:tool_overlay_policy_ref"'),
    (181, '"bee.gateway:tool_publish_policy_ref"', '"bee.gateway.env:tool_publish_policy_ref"'),
    (182, '"bee.gateway:tool_read_policy_ref"', '"bee.gateway.env:tool_read_policy_ref"'),
    (183, '"bee.gateway:tool_session_policy_ref"', '"bee.gateway.env:tool_session_policy_ref"'),
    (184, '"bee.git.worktree:binding"', '"bee.git.worktree.binding:binding"'),
    (185, '"bee.git.worktree:cleanup"', '"bee.git.worktree.binding:cleanup"'),
    (186, '"bee.git.worktree:executor_ref"', '"bee.git.worktree.env:executor_ref"'),
    (187, '"bee.git.worktree:git_executor"', '"bee.git.worktree.env:git_executor"'),
    (188, '"bee.git.worktree:git_roots"', '"bee.git.worktree.binding:git_roots"'),
    (189, '"bee.git.worktree:host_files"', '"bee.git.worktree.env:host_files"'),
    (190, '"bee.git.worktree:host_files_ref"', '"bee.git.worktree.env:host_files_ref"'),
    (191, '"bee.git.worktree:plan"', '"bee.git.worktree.binding:plan"'),
    (192, '"bee.git.worktree:setup"', '"bee.git.worktree.binding:setup"'),
    (193, '"bee.git.worktree:worktree"', '"bee.git.worktree.binding:worktree"'),
    (194, '"bee.git.worktree:worktree_policy"', '"bee.git.worktree.security:worktree_policy"'),
    (195, '"bee.git_worktree:binding"', '"bee.git.worktree.binding:binding"'),
    (196, '"bee.git_worktree:cleanup"', '"bee.git.worktree.binding:cleanup"'),
    (197, '"bee.git_worktree:definition"', '"bee.git.worktree:definition"'),
    (198, '"bee.git_worktree:dependency_driver"', '"bee.git.worktree:dependency_driver"'),
    (199, '"bee.git_worktree:dependency_placement"', '"bee.git.worktree:dependency_placement"'),
    (200, '"bee.git_worktree:dependency_threads"', '"bee.git.worktree:dependency_threads"'),
    (201, '"bee.git_worktree:executor_ref"', '"bee.git.worktree.env:executor_ref"'),
    (202, '"bee.git_worktree:git_executor"', '"bee.git.worktree.env:git_executor"'),
    (203, '"bee.git_worktree:git_roots"', '"bee.git.worktree.binding:git_roots"'),
    (204, '"bee.git_worktree:host_files"', '"bee.git.worktree.env:host_files"'),
    (205, '"bee.git_worktree:host_files_ref"', '"bee.git.worktree.env:host_files_ref"'),
    (206, '"bee.git_worktree:plan"', '"bee.git.worktree.binding:plan"'),
    (207, '"bee.git_worktree:protected_namespace"', '"bee.git.worktree:protected_namespace"'),
    (208, '"bee.git_worktree:setup"', '"bee.git.worktree.binding:setup"'),
    (209, '"bee.git_worktree:target_executor"', '"bee.git.worktree:target_executor"'),
    (210, '"bee.git_worktree:target_host_files"', '"bee.git.worktree:target_host_files"'),
    (211, '"bee.git_worktree:worktree"', '"bee.git.worktree.binding:worktree"'),
    (212, '"bee.git_worktree:worktree_policy"', '"bee.git.worktree.security:worktree_policy"'),
    (213, '"bee.gov.overlays:client_policy"', '"bee.gov.overlays.security:client_policy"'),
    (214, '"bee.gov:activation_measure"', '"bee.gov.activation:activation_measure"'),
    (215, '"bee.gov:activation_profile_decoder"', '"bee.gov.activation:activation_profile_decoder"'),
    (216, '"bee.gov:activation_profiles_ref"', '"bee.gov.env:activation_profiles_ref"'),
    (217, '"bee.gov:application_admissions"', '"bee.gov.activation:application_admissions"'),
    (218, '"bee.gov:approval_consume_policy_ref"', '"bee.gov.env:approval_consume_policy_ref"'),
    (219, '"bee.gov:approval_request_policy_ref"', '"bee.gov.env:approval_request_policy_ref"'),
    (220, '"bee.gov:artifact"', '"bee.gov.delivery:artifact"'),
    (221, '"bee.gov:candidate"', '"bee.gov.delivery:candidate"'),
    (222, '"bee.gov:capability_files"', '"bee.gov.capability:capability_files"'),
    (223, '"bee.gov:capability_gateway"', '"bee.gov.capability:capability_gateway"'),
    (224, '"bee.gov:capability_grants"', '"bee.gov.capability:capability_grants"'),
    (225, '"bee.gov:capability_request"', '"bee.gov.capability:capability_request"'),
    (226, '"bee.gov:database_ref"', '"bee.gov.env:database_ref"'),
    (227, '"bee.gov:db"', '"bee.gov.env:db"'),
    (228, '"bee.gov:db_path"', '"bee.gov.env:db_path"'),
    (229, '"bee.gov:delivery"', '"bee.gov.delivery:delivery"'),
    (230, '"bee.gov:delivery_local"', '"bee.gov.binding:delivery_local"'),
    (231, '"bee.gov:delivery_protocol"', '"bee.gov.delivery:delivery_protocol"'),
    (232, '"bee.gov:environment"', '"bee.gov.env:environment"'),
    (233, '"bee.gov:governed_application_admission"', '"bee.gov.activation:governed_application_admission"'),
    (234, '"bee.gov:headless_revert"', '"bee.gov.activation:headless_revert"'),
    (235, '"bee.gov:hub_resolver"', '"bee.gov.delivery:hub_resolver"'),
    (236, '"bee.gov:lease_model"', '"bee.gov.delivery:lease_model"'),
    (237, '"bee.gov:lists"', '"bee.gov.activation:lists"'),
    (238, '"bee.gov:materializer"', '"bee.gov.delivery:materializer"'),
    (239, '"bee.gov:migration_work"', '"bee.gov.activation:migration_work"'),
    (240, '"bee.gov:node_identity_migration_source"', '"bee.gov.env:node_identity_migration_source"'),
    (241, '"bee.gov:overlay_local"', '"bee.gov.binding:overlay_local"'),
    (242, '"bee.gov:overlay_resolver"', '"bee.gov.delivery:overlay_resolver"'),
    (243, '"bee.gov:preflight"', '"bee.gov.activation:preflight"'),
    (244, '"bee.gov:protected_kernel"', '"bee.gov.activation:protected_kernel"'),
    (245, '"bee.gov:publication_profile_decoder"', '"bee.gov.delivery:publication_profile_decoder"'),
    (246, '"bee.gov:publication_profiles_ref"', '"bee.gov.env:publication_profiles_ref"'),
    (247, '"bee.gov:resolver"', '"bee.gov.delivery:resolver"'),
    (248, '"bee.gov:staging_resources"', '"bee.gov.delivery:staging_resources"'),
    (249, '"bee.gov:super_edit"', '"bee.gov.activation:super_edit"'),
    (250, '"bee.gov:workspace"', '"bee.gov.workspace:workspace"'),
    (251, '"bee.gov:workspace_applications"', '"bee.gov.workspace:workspace_applications"'),
    (252, '"bee.gov:workspace_folder_policy_ref"', '"bee.gov.env:workspace_folder_policy_ref"'),
    (253, '"bee.gov:workspace_folder_read_ref"', '"bee.gov.env:workspace_folder_read_ref"'),
    (254, '"bee.gov:workspace_protocol"', '"bee.gov.workspace:workspace_protocol"'),
    (255, '"bee.harness.carrier:capabilities"', '"bee.harness.binding:capabilities"'),
    (256, '"bee.harness.carrier:process"', '"bee.harness.service:carrier"'),
    (257, '"bee.harness.carrier:types"', '"bee.harness:types"'),
    (258, '"bee.harness.launch:admit"', '"bee.harness.binding:admit"'),
    (259, '"bee.harness.launch:locate_probe"', '"bee.harness.binding:locate_probe"'),
    (260, '"bee.harness.launch:present"', '"bee.harness.binding:present"'),
    (261, '"bee.harness.launch:resolve"', '"bee.harness.binding:resolve"'),
    (262, '"bee.harness.launch:setup"', '"bee.harness.binding:setup"'),
    (263, '"bee.harness.launch:setup_backend"', '"bee.harness.binding:setup_backend"'),
    (264, '"bee.harness.launch:start"', '"bee.harness.binding:start"'),
    (265, '"bee.harness.profiles:call"', '"bee.harness.binding:call"'),
    (266, '"bee.harness.profiles:contract"', '"bee.harness:profiles"'),
    (267, '"bee.harness.profiles:local"', '"bee.harness.binding:profiles_local"'),
    (268, '"bee.harness:carrier_host_ref"', '"bee.harness.env:carrier_host_ref"'),
    (269, '"bee.harness:gateway_hook"', '"bee.harness.api:gateway_hook"'),
    (270, '"bee.harness:gateway_hook_mcp"', '"bee.harness.api:gateway_hook_mcp"'),
    (271, '"bee.harness:gateway_hook_status"', '"bee.harness.api:gateway_hook_status"'),
    (272, '"bee.harness:harness_activation"', '"bee.harness.launch:harness_activation"'),
    (273, '"bee.harness:harness_setup"', '"bee.harness.launch:harness_setup"'),
    (274, '"bee.harness:profiles_local"', '"bee.harness.binding:profiles_local"'),
    (275, '"bee.hive.manager:client_policy"', '"bee.hive.manager.security:client_policy"'),
    (276, '"bee.hive.manager:directory"', '"bee.hive.manager.app:directory"'),
    (277, '"bee.hive.manager:names"', '"bee.hive.manager.app:names"'),
    (278, '"bee.hive.manager:viewer_policy"', '"bee.hive.manager.security:viewer_policy"'),
    (279, '"bee.hive.telemetry:catalog_list"', '"bee.hive.telemetry.binding:catalog_list"'),
    (280, '"bee.hive.telemetry:cluster"', '"bee.hive.telemetry.binding:cluster"'),
    (281, '"bee.hive.telemetry:holdings"', '"bee.hive.telemetry.binding:holdings"'),
    (282, '"bee.hive.telemetry:presence"', '"bee.hive.telemetry.binding:presence"'),
    (283, '"bee.hive.telemetry:sampling"', '"bee.hive.telemetry.binding:sampling"'),
    (284, '"bee.hive.telemetry:stats"', '"bee.hive.telemetry.binding:stats"'),
    (285, '"bee.hive:catalog"', '"bee.hive.exposure:catalog"'),
    (286, '"bee.hive:client"', '"bee.hive.binding:client"'),
    (287, '"bee.hive:invoke_check"', '"bee.hive.binding:invoke_check"'),
    (288, '"bee.hive:output"', '"bee.hive.binding:output"'),
    (289, '"bee.hive:principals"', '"bee.hive.security:principals"'),
    (290, '"bee.hive:workspace_query"', '"bee.hive.workspace:workspace_query"'),
    (291, '"bee.host.processes:probe"', '"bee.host.processes.app:probe"'),
    (292, '"bee.hub.modules:client_policy"', '"bee.hub.modules.security:client_policy"'),
    (293, '"bee.hub.modules:hub_policy"', '"bee.hub.modules.security:hub_policy"'),
    (294, '"bee.hub.modules:publication_policy"', '"bee.hub.modules.security:publication_policy"'),
    (295, '"bee.hub.modules:self_update_policy"', '"bee.hub.modules.security:self_update_policy"'),
    (296, '"bee.hub:binary_identity"', '"bee.hub.package:binary_identity"'),
    (297, '"bee.hub:graph"', '"bee.hub.package:graph"'),
    (298, '"bee.hub:host_resources"', '"bee.hub.activation:host_resources"'),
    (299, '"bee.hub:inspection"', '"bee.hub.package:inspection"'),
    (300, '"bee.hub:installation"', '"bee.hub.activation:installation"'),
    (301, '"bee.hub:inventory"', '"bee.hub.package:inventory"'),
    (302, '"bee.hub:inventory_reader"', '"bee.hub.package:inventory_reader"'),
    (303, '"bee.hub:migration_work"', '"bee.hub.activation:migration_work"'),
    (304, '"bee.hub:migrations"', '"bee.hub.activation:migrations"'),
    (305, '"bee.hub:native_compat"', '"bee.hub.package:native_compat"'),
    (306, '"bee.hub:plan"', '"bee.hub.package:plan"'),
    (307, '"bee.hub:process_host_ref"', '"bee.hub.env:process_host_ref"'),
    (308, '"bee.hub:publish_configuration_ref"', '"bee.hub.env:publish_configuration_ref"'),
    (309, '"bee.hub:publish_executor"', '"bee.hub.publication:publish_executor"'),
    (310, '"bee.hub:publish_executor_ref"', '"bee.hub.env:publish_executor_ref"'),
    (311, '"bee.hub:publishing"', '"bee.hub.publication:publishing"'),
    (312, '"bee.hub:requirements"', '"bee.hub.package:requirements"'),
    (313, '"bee.hub:result"', '"bee.hub.package:result"'),
    (314, '"bee.hub:semver"', '"bee.hub.package:semver"'),
    (315, '"bee.node:database_ref"', '"bee.node.env:database_ref"'),
    (316, '"bee.node:db"', '"bee.node.env:db"'),
    (317, '"bee.node:db_path"', '"bee.node.env:db_path"'),
    (318, '"bee.node:environment"', '"bee.node.env:environment"'),
    (319, '"bee.node:resources"', '"bee.node.env:resources"'),
    (320, '"bee.persist:database"', '"bee.persist.persist:database"'),
    (321, '"bee.persist:ledger"', '"bee.persist.persist:ledger"'),
    (322, '"bee.persist:transaction"', '"bee.persist.persist:transaction"'),
    (323, '"bee.placement.docker:boot_environment"', '"bee.placement.docker.env:boot_environment"'),
    (324, '"bee.placement.docker:coding"', '"bee.placement.docker.profiles:coding"'),
    (325, '"bee.placement.docker:coding_recipe"', '"bee.placement.docker.profiles:coding_recipe"'),
    (326, '"bee.placement.docker:environment"', '"bee.placement.docker.env:environment"'),
    (327, '"bee.placement.docker:environment_configuration"', '"bee.placement.docker.env:environment_configuration"'),
    (328, '"bee.placement.docker:spec"', '"bee.placement.docker.binding:spec"'),
    (329, '"bee.placement.native:admitted_roots_ref"', '"bee.placement.native.env:admitted_roots_ref"'),
    (330, '"bee.placement.native:configuration"', '"bee.placement.native.env:configuration"'),
    (331, '"bee.placement.native:database_ref"', '"bee.placement.native.env:database_ref"'),
    (332, '"bee.placement.native:db"', '"bee.placement.native.env:db"'),
    (333, '"bee.placement.native:db_path"', '"bee.placement.native.env:db_path"'),
    (334, '"bee.placement.native:environment"', '"bee.placement.native.env:environment"'),
    (335, '"bee.placement.native:executor_ref"', '"bee.placement.native.env:executor_ref"'),
    (336, '"bee.placement.native:host_files_ref"', '"bee.placement.native.env:host_files_ref"'),
    (337, '"bee.placement.native:placement_admitted_roots"', '"bee.placement.native.env:placement_admitted_roots"'),
    (338, '"bee.placement.native:placement_executor"', '"bee.placement.native.env:placement_executor"'),
    (339, '"bee.placement.native:placement_host_files"', '"bee.placement.native.env:placement_host_files"'),
    (340, '"bee.placement.native:placement_path"', '"bee.placement.native.env:placement_path"'),
    (341, '"bee.placement.native:placement_resource_mode"', '"bee.placement.native.env:placement_resource_mode"'),
    (342, '"bee.placement.native:placement_workdir_preparers"', '"bee.placement.native.env:placement_workdir_preparers"'),
    (343, '"bee.placement.native:process_backend"', '"bee.placement.native.binding:process_backend"'),
    (344, '"bee.placement.native:process_runner"', '"bee.placement.native.service:process_runner"'),
    (345, '"bee.placement.native:resource_mode_ref"', '"bee.placement.native.env:resource_mode_ref"'),
    (346, '"bee.placement.native:resources"', '"bee.placement.native.env:resources"'),
    (347, '"bee.placement.native:root"', '"bee.placement.native.env:root"'),
    (348, '"bee.placement.native:root_path"', '"bee.placement.native.env:root_path"'),
    (349, '"bee.placement.native:root_ref"', '"bee.placement.native.env:root_ref"'),
    (350, '"bee.placement.native:runner_host_ref"', '"bee.placement.native.env:runner_host_ref"'),
    (351, '"bee.placement.native:workdir_preparers_ref"', '"bee.placement.native.env:workdir_preparers_ref"'),
    (352, '"bee.placement:native"', '"bee.placement.profiles:native"'),
    (353, '"bee.placement:paths"', '"bee.placement.profiles:paths"'),
    (354, '"bee.placement:profiles"', '"bee.placement.profiles:profiles"'),
    (355, '"bee.placement:resolver"', '"bee.placement.binding:resolver"'),
    (356, '"bee.resources:database_ref"', '"bee.resources.env:database_ref"'),
    (357, '"bee.resources:db"', '"bee.resources.env:db"'),
    (358, '"bee.resources:db_path"', '"bee.resources.env:db_path"'),
    (359, '"bee.resources:environment"', '"bee.resources.env:environment"'),
    (360, '"bee.resources:local"', '"bee.resources.binding:local"'),
    (361, '"bee.resources:node_identity_migration_source"', '"bee.resources.env:node_identity_migration_source"'),
    (362, '"bee.resources:resource_roots"', '"bee.resources.env:resource_roots"'),
    (363, '"bee.resources:resources"', '"bee.resources.env:resources"'),
    (364, '"bee.resources:resources_workspace_extension"', '"bee.resources.binding:resources_workspace_extension"'),
    (365, '"bee.resources:roots_ref"', '"bee.resources.env:roots_ref"'),
    (366, '"bee.sessions:driver_route"', '"bee.sessions.executor:driver_route"'),
    (367, '"bee.sessions:executor_registry"', '"bee.sessions.executor:executor_registry"'),
    (368, '"bee.sessions:executor_selection"', '"bee.sessions.executor:executor_selection"'),
    (369, '"bee.sessions:owner"', '"bee.sessions.service:owner"'),
    (370, '"bee.sessions:threads_journal"', '"bee.sessions.binding:threads_journal"'),
    (371, '"bee.sessions:threads_journal_ref"', '"bee.sessions.env:threads_journal_ref"'),
    (372, '"bee.settings:build_info"', '"bee.settings.app:build_info"'),
    (373, '"bee.sync.hive:admit"', '"bee.sync.binding:admit"'),
    (374, '"bee.sync:bounds"', '"bee.sync.values:bounds"'),
    (375, '"bee.sync:canonical"', '"bee.sync.values:canonical"'),
    (376, '"bee.sync:database_ref"', '"bee.sync.env:database_ref"'),
    (377, '"bee.sync:db"', '"bee.sync.env:db"'),
    (378, '"bee.sync:db_path"', '"bee.sync.env:db_path"'),
    (379, '"bee.sync:environment"', '"bee.sync.env:environment"'),
    (380, '"bee.sync:exports_ref"', '"bee.sync.env:exports_ref"'),
    (381, '"bee.sync:resources"', '"bee.sync.env:resources"'),
    (382, '"bee.sync:version"', '"bee.sync.values:version"'),
    (383, '"bee.threads.approvals:append"', '"bee.threads.binding:append"'),
    (384, '"bee.threads.carrier:cancel_intent"', '"bee.threads.binding:cancel_intent"'),
    (385, '"bee.threads.carrier:cancel_status"', '"bee.threads.binding:cancel_status"'),
    (386, '"bee.threads.carrier:checkpoint"', '"bee.threads.binding:checkpoint"'),
    (387, '"bee.threads.carrier:claim"', '"bee.threads.binding:claim"'),
    (388, '"bee.threads.carrier:commit"', '"bee.threads.binding:commit"'),
    (389, '"bee.threads.delivery:ack"', '"bee.threads.binding:ack"'),
    (390, '"bee.threads.delivery:ack_page"', '"bee.threads.binding:ack_page"'),
    (391, '"bee.threads.delivery:claim"', '"bee.threads.binding:delivery_claim"'),
    (392, '"bee.threads.delivery:close_subscription"', '"bee.threads.binding:close_subscription"'),
    (393, '"bee.threads.delivery:dispatch"', '"bee.threads.binding:dispatch"'),
    (394, '"bee.threads.delivery:expire"', '"bee.threads.binding:expire"'),
    (395, '"bee.threads.delivery:forget_subscription"', '"bee.threads.binding:forget_subscription"'),
    (396, '"bee.threads.delivery:page"', '"bee.threads.binding:page"'),
    (397, '"bee.threads.delivery:reconcile"', '"bee.threads.binding:reconcile"'),
    (398, '"bee.threads.delivery:release"', '"bee.threads.binding:release"'),
    (399, '"bee.threads.delivery:resume"', '"bee.threads.binding:resume"'),
    (400, '"bee.threads.delivery:subscribe"', '"bee.threads.binding:subscribe"'),
    (401, '"bee.threads.delivery:unsubscribe"', '"bee.threads.binding:unsubscribe"'),
    (402, '"bee.threads.delivery:wait"', '"bee.threads.binding:wait"'),
    (403, '"bee.threads.delivery:waiter"', '"bee.threads.service:waiter"'),
    (404, '"bee.threads.delivery:waiter_service"', '"bee.threads.service:waiter_service"'),
    (405, '"bee.threads.delivery:watch"', '"bee.threads.binding:watch"'),
    (406, '"bee.threads.projection:recap_read"', '"bee.threads.binding:recap_read"'),
    (407, '"bee.threads.projection:recap_rebuild"', '"bee.threads.binding:recap_rebuild"'),
    (408, '"bee.threads.projection:recap_update"', '"bee.threads.binding:recap_update"'),
    (409, '"bee.threads.projection:status_read"', '"bee.threads.binding:status_read"'),
    (410, '"bee.threads.projection:status_rebuild"', '"bee.threads.binding:status_rebuild"'),
    (411, '"bee.threads.projection:status_update"', '"bee.threads.binding:status_update"'),
    (412, '"bee.threads.records:types"', '"bee.threads:record_types"'),
    (413, '"bee.threads.service:admit_action"', '"bee.threads.binding:admit_action"'),
    (414, '"bee.threads.service:close"', '"bee.threads.binding:close"'),
    (415, '"bee.threads.service:create"', '"bee.threads.binding:create"'),
    (416, '"bee.threads.service:end_turn"', '"bee.threads.binding:end_turn"'),
    (417, '"bee.threads.service:feed_read"', '"bee.threads.binding:feed_read"'),
    (418, '"bee.threads.service:fence_app"', '"bee.threads.binding:fence_app"'),
    (419, '"bee.threads.service:get"', '"bee.threads.binding:get"'),
    (420, '"bee.threads.service:inbox_accept"', '"bee.threads.binding:inbox_accept"'),
    (421, '"bee.threads.service:inbox_ack"', '"bee.threads.binding:inbox_ack"'),
    (422, '"bee.threads.service:inbox_describe"', '"bee.threads.binding:inbox_describe"'),
    (423, '"bee.threads.service:inbox_list"', '"bee.threads.binding:inbox_list"'),
    (424, '"bee.threads.service:inbox_offer"', '"bee.threads.binding:inbox_offer"'),
    (425, '"bee.threads.service:inbox_outbox_claim"', '"bee.threads.binding:inbox_outbox_claim"'),
    (426, '"bee.threads.service:inbox_outbox_settle"', '"bee.threads.binding:inbox_outbox_settle"'),
    (427, '"bee.threads.service:inbox_reply"', '"bee.threads.binding:inbox_reply"'),
    (428, '"bee.threads.service:inbox_resolve"', '"bee.threads.binding:inbox_resolve"'),
    (429, '"bee.threads.service:inbox_send"', '"bee.threads.binding:inbox_send"'),
    (430, '"bee.threads.service:inbox_transport"', '"bee.threads.binding:inbox_transport"'),
    (431, '"bee.threads.service:join"', '"bee.threads.binding:join"'),
    (432, '"bee.threads.service:leave"', '"bee.threads.binding:leave"'),
    (433, '"bee.threads.service:list"', '"bee.threads.binding:list"'),
    (434, '"bee.threads.service:list_workspace"', '"bee.threads.binding:list_workspace"'),
    (435, '"bee.threads.service:notify"', '"bee.threads.binding:notify"'),
    (436, '"bee.threads.service:operation_describe"', '"bee.threads.binding:operation_describe"'),
    (437, '"bee.threads.service:operation_lookup"', '"bee.threads.binding:operation_lookup"'),
    (438, '"bee.threads.service:prepare_attempt"', '"bee.threads.binding:prepare_attempt"'),
    (439, '"bee.threads.service:read_after"', '"bee.threads.binding:read_after"'),
    (440, '"bee.threads.service:receipt"', '"bee.threads.binding:receipt"'),
    (441, '"bee.threads.service:record"', '"bee.threads.binding:record"'),
    (442, '"bee.threads.service:register_app_alias"', '"bee.threads.binding:register_app_alias"'),
    (443, '"bee.threads.service:request_turn"', '"bee.threads.binding:request_turn"'),
    (444, '"bee.threads.service:retire_app_alias"', '"bee.threads.binding:retire_app_alias"'),
    (445, '"bee.threads.service:send"', '"bee.threads.binding:send"'),
    (446, '"bee.threads.service:send_status"', '"bee.threads.binding:send_status"'),
    (447, '"bee.threads.service:session_attach"', '"bee.threads.binding:session_attach"'),
    (448, '"bee.threads.service:session_create"', '"bee.threads.binding:session_create"'),
    (449, '"bee.threads.service:session_describe"', '"bee.threads.binding:session_describe"'),
    (450, '"bee.threads.service:session_scan"', '"bee.threads.binding:session_scan"'),
    (451, '"bee.threads.service:session_transition"', '"bee.threads.binding:session_transition"'),
    (452, '"bee.threads.service:start_attempt"', '"bee.threads.binding:start_attempt"'),
    (453, '"bee.threads.service:turn_accept"', '"bee.threads.binding:turn_accept"'),
    (454, '"bee.threads.service:turn_observation"', '"bee.threads.binding:turn_observation"'),
    (455, '"bee.threads.service:turn_pull"', '"bee.threads.binding:turn_pull"'),
    (456, '"bee.threads.service:turn_recover"', '"bee.threads.binding:turn_recover"'),
    (457, '"bee.threads.service:turn_reserve"', '"bee.threads.binding:turn_reserve"'),
    (458, '"bee.threads.service:types"', '"bee.threads:types"'),
    (459, '"bee.threads.service:work_cancel"', '"bee.threads.binding:work_cancel"'),
    (460, '"bee.threads.service:work_describe"', '"bee.threads.binding:work_describe"'),
    (461, '"bee.threads.service:work_history"', '"bee.threads.binding:work_history"'),
    (462, '"bee.threads.service:work_scan"', '"bee.threads.binding:work_scan"'),
    (463, '"bee.threads.service:work_send"', '"bee.threads.binding:work_send"'),
    (464, '"bee.threads.service:work_settle"', '"bee.threads.binding:work_settle"'),
    (465, '"bee.threads.service:work_uncertain"', '"bee.threads.binding:work_uncertain"'),
    (466, '"bee.threads.timeline:client_policy"', '"bee.threads.timeline.security:client_policy"'),
    (467, '"bee.threads:approvals_local"', '"bee.threads.binding:approvals_local"'),
    (468, '"bee.threads:authority_local"', '"bee.threads.binding:authority_local"'),
    (469, '"bee.threads:capabilities"', '"bee.threads.binding:capabilities"'),
    (470, '"bee.threads:capabilities_report"', '"bee.threads.binding:capabilities_report"'),
    (471, '"bee.threads:carrier_local"', '"bee.threads.binding:carrier_local"'),
    (472, '"bee.threads:database_path"', '"bee.threads.env:database_path"'),
    (473, '"bee.threads:database_ref"', '"bee.threads.env:database_ref"'),
    (474, '"bee.threads:db"', '"bee.threads.env:db"'),
    (475, '"bee.threads:delivery_local"', '"bee.threads.binding:delivery_local"'),
    (476, '"bee.threads:environment"', '"bee.threads.env:environment"'),
    (477, '"bee.threads:journal_local"', '"bee.threads.binding:journal_local"'),
    (478, '"bee.threads:lifecycle_local"', '"bee.threads.binding:lifecycle_local"'),
    (479, '"bee.threads:owner"', '"bee.threads.service:owner"'),
    (480, '"bee.threads:owner_service"', '"bee.threads.service:owner_service"'),
    (481, '"bee.threads:projection_local"', '"bee.threads.binding:projection_local"'),
    (482, '"bee.threads:resources"', '"bee.threads.env:resources"'),
    (483, '"bee.workspace.manager:client_policy"', '"bee.workspace.manager.security:client_policy"'),
    (484, '"bee:approver_policies"', '"bee.security.approvals:approver_policies"'),
    (485, '"bee:capability_catalog"', '"bee.security.capability:capability_catalog"'),
    (486, '"bee:clock"', '"bee.protocol:clock"'),
    (487, '"bee:docs_corpus"', '"bee.env:docs_corpus"'),
    (488, '"bee:gateway_endpoint"', '"bee.gateway.api:gateway_endpoint"'),
    (489, '"bee:gateway_installation_service"', '"bee.gateway.service:gateway_installation_service"'),
    (490, '"bee:gateway_listener"', '"bee.gateway.api:gateway_listener"'),
    (491, '"bee:gateway_mcp"', '"bee.gateway.api:gateway_mcp"'),
    (492, '"bee:gateway_publication_service"', '"bee.gateway.service:gateway_publication_service"'),
    (493, '"bee:gateway_ready"', '"bee.gateway.api:gateway_ready"'),
    (494, '"bee:gateway_router"', '"bee.gateway.api:gateway_router"'),
    (495, '"bee:gateway_workspace_extension"', '"bee.gateway.binding:gateway_workspace_extension"'),
    (496, '"bee:gov_recovery_service"', '"bee.gov.service:gov_recovery_service"'),
    (497, '"bee:hive_operation_adapters"', '"bee.hive.supervisor:hive_operation_adapters"'),
    (498, '"bee:hub_publication"', '"bee.hub.publication:hub_publication"'),
    (499, '"bee:module_installation"', '"bee.gateway.env:module_installation"'),
    (500, '"bee:module_publication"', '"bee.gateway.env:module_publication"'),
    (501, '"bee:protected_kernel"', '"bee.security.gov:protected_kernel"'),
    (502, '"bee:sync_distribution_service"', '"bee.sync.service:sync_distribution_service"'),
    (503, '"bee:sync_exports"', '"bee.sync.env:sync_exports"'),
    (504, '"bee:thread_outbox_pump_service"', '"bee.threads.service:thread_outbox_pump_service"'),
    (505, '"bee:workdir_preparers"', '"bee.placement.native.env:workdir_preparers"'),
    (506, '"bee:workspace_hosts"', '"bee.launch.service:workspace_hosts"'),
    (507, '"bee.app:startup_progress"', '"bee.app.status:startup_progress"'),
    (508, '"bee.persist:startup_progress"', '"bee.persist.env:startup_progress"')]]
local ROOT_REFERENCES_SQL = [[
UPDATE bee_gateway_surfaces SET surface_json = (
  WITH RECURSIVE identity_moves(position, prior, current) AS (VALUES
]] .. ROOT_IDENTITY_VALUES .. [[),
  rewritten(position, value) AS (
    SELECT 0, surface_json
    UNION ALL
    SELECT identity_moves.position, replace(rewritten.value, identity_moves.prior, identity_moves.current)
    FROM rewritten JOIN identity_moves ON identity_moves.position = rewritten.position + 1
  )
  SELECT value FROM rewritten ORDER BY position DESC LIMIT 1
) WHERE json_valid(surface_json) AND instr(surface_json, 'bee') > 0;
UPDATE bee_gateway_surfaces SET active_json = (
  WITH RECURSIVE identity_moves(position, prior, current) AS (VALUES
]] .. ROOT_IDENTITY_VALUES .. [[),
  rewritten(position, value) AS (
    SELECT 0, active_json
    UNION ALL
    SELECT identity_moves.position, replace(rewritten.value, identity_moves.prior, identity_moves.current)
    FROM rewritten JOIN identity_moves ON identity_moves.position = rewritten.position + 1
  )
  SELECT value FROM rewritten ORDER BY position DESC LIMIT 1
) WHERE json_valid(active_json) AND instr(active_json, 'bee') > 0;
UPDATE bee_gateway_access_grants SET traits_json = (
  WITH RECURSIVE identity_moves(position, prior, current) AS (VALUES
]] .. ROOT_IDENTITY_VALUES .. [[),
  rewritten(position, value) AS (
    SELECT 0, traits_json
    UNION ALL
    SELECT identity_moves.position, replace(rewritten.value, identity_moves.prior, identity_moves.current)
    FROM rewritten JOIN identity_moves ON identity_moves.position = rewritten.position + 1
  )
  SELECT value FROM rewritten ORDER BY position DESC LIMIT 1
) WHERE json_valid(traits_json) AND instr(traits_json, 'bee') > 0;
UPDATE bee_gateway_bindings SET policy_ref = 'bee.approvals.inbox.app:client' WHERE policy_ref = 'bee.approvals.inbox:client';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.approvals.inbox.security:client_policy' WHERE policy_ref = 'bee.approvals.inbox:client_policy';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.approvals.inbox.app:source_config' WHERE policy_ref = 'bee.approvals.inbox:source_config';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.approvals.inbox.app:sources' WHERE policy_ref = 'bee.approvals.inbox:sources';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.approvals.inbox.app:workspaces' WHERE policy_ref = 'bee.approvals.inbox:workspaces';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.approvals.env:database_ref' WHERE policy_ref = 'bee.approvals:database_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.approvals.env:db' WHERE policy_ref = 'bee.approvals:db';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.approvals.env:db_path' WHERE policy_ref = 'bee.approvals:db_path';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.approvals.env:environment' WHERE policy_ref = 'bee.approvals:environment';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.approvals.migrations:identity_migration' WHERE policy_ref = 'bee.approvals:identity_migration';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.approvals.binding:local' WHERE policy_ref = 'bee.approvals:local';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.approvals.env:node_identity_migration_source' WHERE policy_ref = 'bee.approvals:node_identity_migration_source';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.approvals.env:policies_ref' WHERE policy_ref = 'bee.approvals:policies_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.approvals.env:resources' WHERE policy_ref = 'bee.approvals:resources';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.approvals.service:runtime_lease' WHERE policy_ref = 'bee.approvals:runtime_lease';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.approvals.service:service' WHERE policy_ref = 'bee.approvals:service';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.console.app:command' WHERE policy_ref = 'bee.console:command';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.console.security:command_policy' WHERE policy_ref = 'bee.console:command_policy';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.console.env:environment' WHERE policy_ref = 'bee.console:environment';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.console.env:executor' WHERE policy_ref = 'bee.console:executor';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.console.security:executor_policy' WHERE policy_ref = 'bee.console:executor_policy';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.console.env:home' WHERE policy_ref = 'bee.console:home';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.console.env:lang' WHERE policy_ref = 'bee.console:lang';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.console.env:path' WHERE policy_ref = 'bee.console:path';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.console.env:user' WHERE policy_ref = 'bee.console:user';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.credentials.env:credential_sources' WHERE policy_ref = 'bee.credentials:credential_sources';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.credentials.env:database_ref' WHERE policy_ref = 'bee.credentials:database_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.credentials.env:db' WHERE policy_ref = 'bee.credentials:db';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.credentials.env:db_path' WHERE policy_ref = 'bee.credentials:db_path';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.credentials.env:environment' WHERE policy_ref = 'bee.credentials:environment';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.credentials.binding:local' WHERE policy_ref = 'bee.credentials:local';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.credentials.env:materializer_ref' WHERE policy_ref = 'bee.credentials:materializer_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.credentials.env:node_identity_migration_source' WHERE policy_ref = 'bee.credentials:node_identity_migration_source';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.credentials.env:sources' WHERE policy_ref = 'bee.credentials:sources';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.credentials.env:sources_ref' WHERE policy_ref = 'bee.credentials:sources_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.docs.binding:corpus' WHERE policy_ref = 'bee.docs:corpus';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.docs.env:corpus_ref' WHERE policy_ref = 'bee.docs:corpus_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.docs.env:resources' WHERE policy_ref = 'bee.docs:resources';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.agy.binding:binding' WHERE policy_ref = 'bee.driver.agy:binding';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.agy.descriptor:command' WHERE policy_ref = 'bee.driver.agy:command';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.agy.binding:configuration' WHERE policy_ref = 'bee.driver.agy:configuration';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.agy.credentials:credential_format' WHERE policy_ref = 'bee.driver.agy:credential_format';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.agy.profiles:default_window' WHERE policy_ref = 'bee.driver.agy:default_window';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.agy.env:executable' WHERE policy_ref = 'bee.driver.agy:executable';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.agy.binding:launch' WHERE policy_ref = 'bee.driver.agy:launch';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.agy.security:launch_policy_agy_batch' WHERE policy_ref = 'bee.driver.agy:launch_policy_agy_batch';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.agy.security:launch_policy_agy_window' WHERE policy_ref = 'bee.driver.agy:launch_policy_agy_window';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.agy.descriptor:locate' WHERE policy_ref = 'bee.driver.agy:locate';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.agy.profiles:profiles' WHERE policy_ref = 'bee.driver.agy:profiles';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.agy.binding:protocol' WHERE policy_ref = 'bee.driver.agy:protocol';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.agy.profiles:research_batch' WHERE policy_ref = 'bee.driver.agy:research_batch';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.claude.env:api_key' WHERE policy_ref = 'bee.driver.claude:api_key';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.claude.binding:binding' WHERE policy_ref = 'bee.driver.claude:binding';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.claude.descriptor:command' WHERE policy_ref = 'bee.driver.claude:command';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.claude.env:config_home' WHERE policy_ref = 'bee.driver.claude:config_home';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.claude.credentials:credential_format' WHERE policy_ref = 'bee.driver.claude:credential_format';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.claude.profiles:default_window' WHERE policy_ref = 'bee.driver.claude:default_window';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.claude.env:executable' WHERE policy_ref = 'bee.driver.claude:executable';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.claude.binding:launch' WHERE policy_ref = 'bee.driver.claude:launch';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.claude.security:launch_policy_claude_batch' WHERE policy_ref = 'bee.driver.claude:launch_policy_claude_batch';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.claude.security:launch_policy_claude_window' WHERE policy_ref = 'bee.driver.claude:launch_policy_claude_window';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.claude.descriptor:locate' WHERE policy_ref = 'bee.driver.claude:locate';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.claude.permission:permission_adapter' WHERE policy_ref = 'bee.driver.claude:permission_adapter';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.claude.profiles:profiles' WHERE policy_ref = 'bee.driver.claude:profiles';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.claude.binding:protocol' WHERE policy_ref = 'bee.driver.claude:protocol';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.claude.profiles:research_batch' WHERE policy_ref = 'bee.driver.claude:research_batch';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.codex.binding:binding' WHERE policy_ref = 'bee.driver.codex:binding';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.codex.descriptor:command' WHERE policy_ref = 'bee.driver.codex:command';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.codex.env:config_home' WHERE policy_ref = 'bee.driver.codex:config_home';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.codex.binding:configuration' WHERE policy_ref = 'bee.driver.codex:configuration';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.codex.credentials:credential_format' WHERE policy_ref = 'bee.driver.codex:credential_format';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.codex.descriptor:default_provider' WHERE policy_ref = 'bee.driver.codex:default_provider';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.codex.profiles:default_window' WHERE policy_ref = 'bee.driver.codex:default_window';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.codex.env:executable' WHERE policy_ref = 'bee.driver.codex:executable';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.codex.binding:launch' WHERE policy_ref = 'bee.driver.codex:launch';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.codex.security:launch_policy_codex_batch' WHERE policy_ref = 'bee.driver.codex:launch_policy_codex_batch';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.codex.security:launch_policy_codex_named_batch' WHERE policy_ref = 'bee.driver.codex:launch_policy_codex_named_batch';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.codex.security:launch_policy_codex_window' WHERE policy_ref = 'bee.driver.codex:launch_policy_codex_window';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.codex.descriptor:locate' WHERE policy_ref = 'bee.driver.codex:locate';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.codex.profiles:named_batch' WHERE policy_ref = 'bee.driver.codex:named_batch';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.codex.profiles:profiles' WHERE policy_ref = 'bee.driver.codex:profiles';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.codex.binding:protocol' WHERE policy_ref = 'bee.driver.codex:protocol';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.codex.profiles:research_batch' WHERE policy_ref = 'bee.driver.codex:research_batch';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.grok.binding:binding' WHERE policy_ref = 'bee.driver.grok:binding';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.grok.descriptor:command' WHERE policy_ref = 'bee.driver.grok:command';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.grok.binding:configuration' WHERE policy_ref = 'bee.driver.grok:configuration';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.grok.credentials:credential_format' WHERE policy_ref = 'bee.driver.grok:credential_format';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.grok.profiles:default_window' WHERE policy_ref = 'bee.driver.grok:default_window';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.grok.env:executable' WHERE policy_ref = 'bee.driver.grok:executable';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.grok.binding:launch' WHERE policy_ref = 'bee.driver.grok:launch';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.grok.security:launch_policy_grok_batch' WHERE policy_ref = 'bee.driver.grok:launch_policy_grok_batch';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.grok.security:launch_policy_grok_window' WHERE policy_ref = 'bee.driver.grok:launch_policy_grok_window';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.grok.descriptor:locate' WHERE policy_ref = 'bee.driver.grok:locate';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.grok.profiles:profiles' WHERE policy_ref = 'bee.driver.grok:profiles';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.grok.binding:protocol' WHERE policy_ref = 'bee.driver.grok:protocol';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.grok.profiles:research_batch' WHERE policy_ref = 'bee.driver.grok:research_batch';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.muse.binding:binding' WHERE policy_ref = 'bee.driver.muse:binding';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.muse.descriptor:command' WHERE policy_ref = 'bee.driver.muse:command';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.muse.binding:configuration' WHERE policy_ref = 'bee.driver.muse:configuration';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.muse.credentials:credential_format' WHERE policy_ref = 'bee.driver.muse:credential_format';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.muse.profiles:default_window' WHERE policy_ref = 'bee.driver.muse:default_window';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.muse.env:executable' WHERE policy_ref = 'bee.driver.muse:executable';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.muse.binding:launch' WHERE policy_ref = 'bee.driver.muse:launch';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.muse.security:launch_policy_muse_batch' WHERE policy_ref = 'bee.driver.muse:launch_policy_muse_batch';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.muse.security:launch_policy_muse_window' WHERE policy_ref = 'bee.driver.muse:launch_policy_muse_window';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.muse.descriptor:locate' WHERE policy_ref = 'bee.driver.muse:locate';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.muse.profiles:profiles' WHERE policy_ref = 'bee.driver.muse:profiles';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.muse.binding:protocol' WHERE policy_ref = 'bee.driver.muse:protocol';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.muse.profiles:research_batch' WHERE policy_ref = 'bee.driver.muse:research_batch';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.opencode.binding:binding' WHERE policy_ref = 'bee.driver.opencode:binding';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.opencode.descriptor:command' WHERE policy_ref = 'bee.driver.opencode:command';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.opencode.binding:configuration' WHERE policy_ref = 'bee.driver.opencode:configuration';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.opencode.credentials:credential_format' WHERE policy_ref = 'bee.driver.opencode:credential_format';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.opencode.profiles:default_window' WHERE policy_ref = 'bee.driver.opencode:default_window';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.opencode.env:executable' WHERE policy_ref = 'bee.driver.opencode:executable';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.opencode.binding:launch' WHERE policy_ref = 'bee.driver.opencode:launch';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.opencode.security:launch_policy_opencode_batch' WHERE policy_ref = 'bee.driver.opencode:launch_policy_opencode_batch';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.opencode.security:launch_policy_opencode_window' WHERE policy_ref = 'bee.driver.opencode:launch_policy_opencode_window';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.opencode.descriptor:locate' WHERE policy_ref = 'bee.driver.opencode:locate';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.opencode.profiles:profiles' WHERE policy_ref = 'bee.driver.opencode:profiles';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.opencode.binding:protocol' WHERE policy_ref = 'bee.driver.opencode:protocol';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.opencode.profiles:research_batch' WHERE policy_ref = 'bee.driver.opencode:research_batch';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.wippy.binding:binding' WHERE policy_ref = 'bee.driver.wippy:binding';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.wippy.binding:client' WHERE policy_ref = 'bee.driver.wippy:client';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.wippy.env:host_config' WHERE policy_ref = 'bee.driver.wippy:host_config';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.wippy.profiles:profiles' WHERE policy_ref = 'bee.driver.wippy:profiles';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.wippy.binding:run' WHERE policy_ref = 'bee.driver.wippy:run';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.wippy.service:runner' WHERE policy_ref = 'bee.driver.wippy:runner';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.codec:codec_registry' WHERE policy_ref = 'bee.driver:codec_registry';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.configuration:configuration' WHERE policy_ref = 'bee.driver:configuration';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.descriptor:descriptor' WHERE policy_ref = 'bee.driver:descriptor';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.profiles:instructions' WHERE policy_ref = 'bee.driver:instructions';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.locate:locate' WHERE policy_ref = 'bee.driver:locate';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.locate:login_evidence' WHERE policy_ref = 'bee.driver:login_evidence';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.configuration:option_render' WHERE policy_ref = 'bee.driver:option_render';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.permission:permission_request_hook' WHERE policy_ref = 'bee.driver:permission_request_hook';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.profiles:preferences' WHERE policy_ref = 'bee.driver:preferences';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.locate:probe_capture' WHERE policy_ref = 'bee.driver:probe_capture';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.profiles:profile' WHERE policy_ref = 'bee.driver:profile';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.profiles:profile_access' WHERE policy_ref = 'bee.driver:profile_access';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.binding:resolver' WHERE policy_ref = 'bee.driver:resolver';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.descriptor:schema_values' WHERE policy_ref = 'bee.driver:schema_values';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.driver.binding:universal' WHERE policy_ref = 'bee.driver:universal';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.files.app:gitignore' WHERE policy_ref = 'bee.files:gitignore';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.files.app:source' WHERE policy_ref = 'bee.files:source';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.files.app:syntax' WHERE policy_ref = 'bee.files:syntax';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.files.app:tree' WHERE policy_ref = 'bee.files:tree';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.files.env:workspace_root_ref' WHERE policy_ref = 'bee.files:workspace_root_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.binding:address' WHERE policy_ref = 'bee.gateway:address';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.api:address_value' WHERE policy_ref = 'bee.gateway:address_value';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.env:approval_consume_policy_ref' WHERE policy_ref = 'bee.gateway:approval_consume_policy_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.env:approval_request_policy_ref' WHERE policy_ref = 'bee.gateway:approval_request_policy_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.catalog:catalog' WHERE policy_ref = 'bee.gateway:catalog';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.env:configuration' WHERE policy_ref = 'bee.gateway:configuration';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.catalog:context' WHERE policy_ref = 'bee.gateway:context';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.env:database_ref' WHERE policy_ref = 'bee.gateway:database_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.env:db' WHERE policy_ref = 'bee.gateway:db';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.env:db_path' WHERE policy_ref = 'bee.gateway:db_path';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.env:endpoint_ref' WHERE policy_ref = 'bee.gateway:endpoint_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.env:environment' WHERE policy_ref = 'bee.gateway:environment';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.env:hook_executable' WHERE policy_ref = 'bee.gateway:hook_executable';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.hooks:hooks' WHERE policy_ref = 'bee.gateway:hooks';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.env:install_configuration_ref' WHERE policy_ref = 'bee.gateway:install_configuration_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.catalog:json_schema' WHERE policy_ref = 'bee.gateway:json_schema';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.env:listener_ref' WHERE policy_ref = 'bee.gateway:listener_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.api:mcp' WHERE policy_ref = 'bee.gateway:mcp';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.catalog:profile_scope' WHERE policy_ref = 'bee.gateway:profile_scope';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.env:publish_configuration_ref' WHERE policy_ref = 'bee.gateway:publish_configuration_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.catalog:session_bundle' WHERE policy_ref = 'bee.gateway:session_bundle';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.catalog:session_tools' WHERE policy_ref = 'bee.gateway:session_tools';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.catalog:sessions' WHERE policy_ref = 'bee.gateway:sessions';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.catalog:surface' WHERE policy_ref = 'bee.gateway:surface';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.env:tool_application_open_policy_ref' WHERE policy_ref = 'bee.gateway:tool_application_open_policy_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.env:tool_components_policy_ref' WHERE policy_ref = 'bee.gateway:tool_components_policy_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.env:tool_delivery_policy_ref' WHERE policy_ref = 'bee.gateway:tool_delivery_policy_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.env:tool_docs_policy_ref' WHERE policy_ref = 'bee.gateway:tool_docs_policy_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.env:tool_hub_publish_policy_ref' WHERE policy_ref = 'bee.gateway:tool_hub_publish_policy_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.env:tool_install_policy_ref' WHERE policy_ref = 'bee.gateway:tool_install_policy_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.env:tool_message_policy_ref' WHERE policy_ref = 'bee.gateway:tool_message_policy_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.env:tool_overlay_policy_ref' WHERE policy_ref = 'bee.gateway:tool_overlay_policy_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.env:tool_publish_policy_ref' WHERE policy_ref = 'bee.gateway:tool_publish_policy_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.env:tool_read_policy_ref' WHERE policy_ref = 'bee.gateway:tool_read_policy_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.env:tool_session_policy_ref' WHERE policy_ref = 'bee.gateway:tool_session_policy_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.git.worktree.binding:binding' WHERE policy_ref = 'bee.git.worktree:binding';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.git.worktree.binding:cleanup' WHERE policy_ref = 'bee.git.worktree:cleanup';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.git.worktree.env:executor_ref' WHERE policy_ref = 'bee.git.worktree:executor_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.git.worktree.env:git_executor' WHERE policy_ref = 'bee.git.worktree:git_executor';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.git.worktree.binding:git_roots' WHERE policy_ref = 'bee.git.worktree:git_roots';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.git.worktree.env:host_files' WHERE policy_ref = 'bee.git.worktree:host_files';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.git.worktree.env:host_files_ref' WHERE policy_ref = 'bee.git.worktree:host_files_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.git.worktree.binding:plan' WHERE policy_ref = 'bee.git.worktree:plan';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.git.worktree.binding:setup' WHERE policy_ref = 'bee.git.worktree:setup';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.git.worktree.binding:worktree' WHERE policy_ref = 'bee.git.worktree:worktree';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.git.worktree.security:worktree_policy' WHERE policy_ref = 'bee.git.worktree:worktree_policy';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.git.worktree.binding:binding' WHERE policy_ref = 'bee.git_worktree:binding';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.git.worktree.binding:cleanup' WHERE policy_ref = 'bee.git_worktree:cleanup';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.git.worktree:definition' WHERE policy_ref = 'bee.git_worktree:definition';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.git.worktree:dependency_driver' WHERE policy_ref = 'bee.git_worktree:dependency_driver';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.git.worktree:dependency_placement' WHERE policy_ref = 'bee.git_worktree:dependency_placement';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.git.worktree:dependency_threads' WHERE policy_ref = 'bee.git_worktree:dependency_threads';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.git.worktree.env:executor_ref' WHERE policy_ref = 'bee.git_worktree:executor_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.git.worktree.env:git_executor' WHERE policy_ref = 'bee.git_worktree:git_executor';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.git.worktree.binding:git_roots' WHERE policy_ref = 'bee.git_worktree:git_roots';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.git.worktree.env:host_files' WHERE policy_ref = 'bee.git_worktree:host_files';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.git.worktree.env:host_files_ref' WHERE policy_ref = 'bee.git_worktree:host_files_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.git.worktree.binding:plan' WHERE policy_ref = 'bee.git_worktree:plan';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.git.worktree:protected_namespace' WHERE policy_ref = 'bee.git_worktree:protected_namespace';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.git.worktree.binding:setup' WHERE policy_ref = 'bee.git_worktree:setup';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.git.worktree:target_executor' WHERE policy_ref = 'bee.git_worktree:target_executor';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.git.worktree:target_host_files' WHERE policy_ref = 'bee.git_worktree:target_host_files';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.git.worktree.binding:worktree' WHERE policy_ref = 'bee.git_worktree:worktree';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.git.worktree.security:worktree_policy' WHERE policy_ref = 'bee.git_worktree:worktree_policy';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.overlays.security:client_policy' WHERE policy_ref = 'bee.gov.overlays:client_policy';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.activation:activation_measure' WHERE policy_ref = 'bee.gov:activation_measure';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.activation:activation_profile_decoder' WHERE policy_ref = 'bee.gov:activation_profile_decoder';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.env:activation_profiles_ref' WHERE policy_ref = 'bee.gov:activation_profiles_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.activation:application_admissions' WHERE policy_ref = 'bee.gov:application_admissions';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.env:approval_consume_policy_ref' WHERE policy_ref = 'bee.gov:approval_consume_policy_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.env:approval_request_policy_ref' WHERE policy_ref = 'bee.gov:approval_request_policy_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.delivery:artifact' WHERE policy_ref = 'bee.gov:artifact';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.delivery:candidate' WHERE policy_ref = 'bee.gov:candidate';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.capability:capability_files' WHERE policy_ref = 'bee.gov:capability_files';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.capability:capability_gateway' WHERE policy_ref = 'bee.gov:capability_gateway';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.capability:capability_grants' WHERE policy_ref = 'bee.gov:capability_grants';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.capability:capability_request' WHERE policy_ref = 'bee.gov:capability_request';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.env:database_ref' WHERE policy_ref = 'bee.gov:database_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.env:db' WHERE policy_ref = 'bee.gov:db';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.env:db_path' WHERE policy_ref = 'bee.gov:db_path';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.delivery:delivery' WHERE policy_ref = 'bee.gov:delivery';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.binding:delivery_local' WHERE policy_ref = 'bee.gov:delivery_local';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.delivery:delivery_protocol' WHERE policy_ref = 'bee.gov:delivery_protocol';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.env:environment' WHERE policy_ref = 'bee.gov:environment';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.activation:governed_application_admission' WHERE policy_ref = 'bee.gov:governed_application_admission';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.activation:headless_revert' WHERE policy_ref = 'bee.gov:headless_revert';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.delivery:hub_resolver' WHERE policy_ref = 'bee.gov:hub_resolver';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.delivery:lease_model' WHERE policy_ref = 'bee.gov:lease_model';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.activation:lists' WHERE policy_ref = 'bee.gov:lists';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.delivery:materializer' WHERE policy_ref = 'bee.gov:materializer';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.activation:migration_work' WHERE policy_ref = 'bee.gov:migration_work';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.env:node_identity_migration_source' WHERE policy_ref = 'bee.gov:node_identity_migration_source';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.binding:overlay_local' WHERE policy_ref = 'bee.gov:overlay_local';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.delivery:overlay_resolver' WHERE policy_ref = 'bee.gov:overlay_resolver';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.activation:preflight' WHERE policy_ref = 'bee.gov:preflight';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.activation:protected_kernel' WHERE policy_ref = 'bee.gov:protected_kernel';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.delivery:publication_profile_decoder' WHERE policy_ref = 'bee.gov:publication_profile_decoder';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.env:publication_profiles_ref' WHERE policy_ref = 'bee.gov:publication_profiles_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.delivery:resolver' WHERE policy_ref = 'bee.gov:resolver';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.delivery:staging_resources' WHERE policy_ref = 'bee.gov:staging_resources';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.activation:super_edit' WHERE policy_ref = 'bee.gov:super_edit';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.workspace:workspace' WHERE policy_ref = 'bee.gov:workspace';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.workspace:workspace_applications' WHERE policy_ref = 'bee.gov:workspace_applications';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.env:workspace_folder_policy_ref' WHERE policy_ref = 'bee.gov:workspace_folder_policy_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.env:workspace_folder_read_ref' WHERE policy_ref = 'bee.gov:workspace_folder_read_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.workspace:workspace_protocol' WHERE policy_ref = 'bee.gov:workspace_protocol';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.harness.binding:capabilities' WHERE policy_ref = 'bee.harness.carrier:capabilities';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.harness.service:carrier' WHERE policy_ref = 'bee.harness.carrier:process';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.harness:types' WHERE policy_ref = 'bee.harness.carrier:types';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.harness.binding:admit' WHERE policy_ref = 'bee.harness.launch:admit';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.harness.binding:locate_probe' WHERE policy_ref = 'bee.harness.launch:locate_probe';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.harness.binding:present' WHERE policy_ref = 'bee.harness.launch:present';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.harness.binding:resolve' WHERE policy_ref = 'bee.harness.launch:resolve';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.harness.binding:setup' WHERE policy_ref = 'bee.harness.launch:setup';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.harness.binding:setup_backend' WHERE policy_ref = 'bee.harness.launch:setup_backend';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.harness.binding:start' WHERE policy_ref = 'bee.harness.launch:start';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.harness.binding:call' WHERE policy_ref = 'bee.harness.profiles:call';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.harness:profiles' WHERE policy_ref = 'bee.harness.profiles:contract';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.harness.binding:profiles_local' WHERE policy_ref = 'bee.harness.profiles:local';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.harness.env:carrier_host_ref' WHERE policy_ref = 'bee.harness:carrier_host_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.harness.api:gateway_hook' WHERE policy_ref = 'bee.harness:gateway_hook';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.harness.api:gateway_hook_mcp' WHERE policy_ref = 'bee.harness:gateway_hook_mcp';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.harness.api:gateway_hook_status' WHERE policy_ref = 'bee.harness:gateway_hook_status';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.harness.launch:harness_activation' WHERE policy_ref = 'bee.harness:harness_activation';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.harness.launch:harness_setup' WHERE policy_ref = 'bee.harness:harness_setup';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.harness.binding:profiles_local' WHERE policy_ref = 'bee.harness:profiles_local';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.manager.security:client_policy' WHERE policy_ref = 'bee.hive.manager:client_policy';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.manager.app:directory' WHERE policy_ref = 'bee.hive.manager:directory';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.manager.app:names' WHERE policy_ref = 'bee.hive.manager:names';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.manager.security:viewer_policy' WHERE policy_ref = 'bee.hive.manager:viewer_policy';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.telemetry.binding:catalog_list' WHERE policy_ref = 'bee.hive.telemetry:catalog_list';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.telemetry.binding:cluster' WHERE policy_ref = 'bee.hive.telemetry:cluster';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.telemetry.binding:holdings' WHERE policy_ref = 'bee.hive.telemetry:holdings';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.telemetry.binding:presence' WHERE policy_ref = 'bee.hive.telemetry:presence';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.telemetry.binding:sampling' WHERE policy_ref = 'bee.hive.telemetry:sampling';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.telemetry.binding:stats' WHERE policy_ref = 'bee.hive.telemetry:stats';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.exposure:catalog' WHERE policy_ref = 'bee.hive:catalog';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.binding:client' WHERE policy_ref = 'bee.hive:client';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.binding:invoke_check' WHERE policy_ref = 'bee.hive:invoke_check';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.binding:output' WHERE policy_ref = 'bee.hive:output';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.security:principals' WHERE policy_ref = 'bee.hive:principals';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.workspace:workspace_query' WHERE policy_ref = 'bee.hive:workspace_query';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.host.processes.app:probe' WHERE policy_ref = 'bee.host.processes:probe';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hub.modules.security:client_policy' WHERE policy_ref = 'bee.hub.modules:client_policy';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hub.modules.security:hub_policy' WHERE policy_ref = 'bee.hub.modules:hub_policy';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hub.modules.security:publication_policy' WHERE policy_ref = 'bee.hub.modules:publication_policy';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hub.modules.security:self_update_policy' WHERE policy_ref = 'bee.hub.modules:self_update_policy';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hub.package:binary_identity' WHERE policy_ref = 'bee.hub:binary_identity';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hub.package:graph' WHERE policy_ref = 'bee.hub:graph';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hub.activation:host_resources' WHERE policy_ref = 'bee.hub:host_resources';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hub.package:inspection' WHERE policy_ref = 'bee.hub:inspection';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hub.activation:installation' WHERE policy_ref = 'bee.hub:installation';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hub.package:inventory' WHERE policy_ref = 'bee.hub:inventory';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hub.package:inventory_reader' WHERE policy_ref = 'bee.hub:inventory_reader';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hub.activation:migration_work' WHERE policy_ref = 'bee.hub:migration_work';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hub.activation:migrations' WHERE policy_ref = 'bee.hub:migrations';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hub.package:native_compat' WHERE policy_ref = 'bee.hub:native_compat';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hub.package:plan' WHERE policy_ref = 'bee.hub:plan';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hub.env:process_host_ref' WHERE policy_ref = 'bee.hub:process_host_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hub.env:publish_configuration_ref' WHERE policy_ref = 'bee.hub:publish_configuration_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hub.publication:publish_executor' WHERE policy_ref = 'bee.hub:publish_executor';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hub.env:publish_executor_ref' WHERE policy_ref = 'bee.hub:publish_executor_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hub.publication:publishing' WHERE policy_ref = 'bee.hub:publishing';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hub.package:requirements' WHERE policy_ref = 'bee.hub:requirements';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hub.package:result' WHERE policy_ref = 'bee.hub:result';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hub.package:semver' WHERE policy_ref = 'bee.hub:semver';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.node.env:database_ref' WHERE policy_ref = 'bee.node:database_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.node.env:db' WHERE policy_ref = 'bee.node:db';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.node.env:db_path' WHERE policy_ref = 'bee.node:db_path';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.node.env:environment' WHERE policy_ref = 'bee.node:environment';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.node.env:resources' WHERE policy_ref = 'bee.node:resources';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.persist.persist:database' WHERE policy_ref = 'bee.persist:database';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.persist.persist:ledger' WHERE policy_ref = 'bee.persist:ledger';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.persist.persist:transaction' WHERE policy_ref = 'bee.persist:transaction';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.docker.env:boot_environment' WHERE policy_ref = 'bee.placement.docker:boot_environment';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.docker.profiles:coding' WHERE policy_ref = 'bee.placement.docker:coding';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.docker.profiles:coding_recipe' WHERE policy_ref = 'bee.placement.docker:coding_recipe';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.docker.env:environment' WHERE policy_ref = 'bee.placement.docker:environment';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.docker.env:environment_configuration' WHERE policy_ref = 'bee.placement.docker:environment_configuration';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.docker.binding:spec' WHERE policy_ref = 'bee.placement.docker:spec';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.native.env:admitted_roots_ref' WHERE policy_ref = 'bee.placement.native:admitted_roots_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.native.env:configuration' WHERE policy_ref = 'bee.placement.native:configuration';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.native.env:database_ref' WHERE policy_ref = 'bee.placement.native:database_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.native.env:db' WHERE policy_ref = 'bee.placement.native:db';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.native.env:db_path' WHERE policy_ref = 'bee.placement.native:db_path';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.native.env:environment' WHERE policy_ref = 'bee.placement.native:environment';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.native.env:executor_ref' WHERE policy_ref = 'bee.placement.native:executor_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.native.env:host_files_ref' WHERE policy_ref = 'bee.placement.native:host_files_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.native.env:placement_admitted_roots' WHERE policy_ref = 'bee.placement.native:placement_admitted_roots';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.native.env:placement_executor' WHERE policy_ref = 'bee.placement.native:placement_executor';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.native.env:placement_host_files' WHERE policy_ref = 'bee.placement.native:placement_host_files';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.native.env:placement_path' WHERE policy_ref = 'bee.placement.native:placement_path';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.native.env:placement_resource_mode' WHERE policy_ref = 'bee.placement.native:placement_resource_mode';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.native.env:placement_workdir_preparers' WHERE policy_ref = 'bee.placement.native:placement_workdir_preparers';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.native.binding:process_backend' WHERE policy_ref = 'bee.placement.native:process_backend';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.native.service:process_runner' WHERE policy_ref = 'bee.placement.native:process_runner';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.native.env:resource_mode_ref' WHERE policy_ref = 'bee.placement.native:resource_mode_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.native.env:resources' WHERE policy_ref = 'bee.placement.native:resources';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.native.env:root' WHERE policy_ref = 'bee.placement.native:root';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.native.env:root_path' WHERE policy_ref = 'bee.placement.native:root_path';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.native.env:root_ref' WHERE policy_ref = 'bee.placement.native:root_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.native.env:runner_host_ref' WHERE policy_ref = 'bee.placement.native:runner_host_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.native.env:workdir_preparers_ref' WHERE policy_ref = 'bee.placement.native:workdir_preparers_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.profiles:native' WHERE policy_ref = 'bee.placement:native';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.profiles:paths' WHERE policy_ref = 'bee.placement:paths';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.profiles:profiles' WHERE policy_ref = 'bee.placement:profiles';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.binding:resolver' WHERE policy_ref = 'bee.placement:resolver';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.resources.env:database_ref' WHERE policy_ref = 'bee.resources:database_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.resources.env:db' WHERE policy_ref = 'bee.resources:db';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.resources.env:db_path' WHERE policy_ref = 'bee.resources:db_path';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.resources.env:environment' WHERE policy_ref = 'bee.resources:environment';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.resources.binding:local' WHERE policy_ref = 'bee.resources:local';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.resources.env:node_identity_migration_source' WHERE policy_ref = 'bee.resources:node_identity_migration_source';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.resources.env:resource_roots' WHERE policy_ref = 'bee.resources:resource_roots';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.resources.env:resources' WHERE policy_ref = 'bee.resources:resources';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.resources.binding:resources_workspace_extension' WHERE policy_ref = 'bee.resources:resources_workspace_extension';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.resources.env:roots_ref' WHERE policy_ref = 'bee.resources:roots_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.sessions.executor:driver_route' WHERE policy_ref = 'bee.sessions:driver_route';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.sessions.executor:executor_registry' WHERE policy_ref = 'bee.sessions:executor_registry';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.sessions.executor:executor_selection' WHERE policy_ref = 'bee.sessions:executor_selection';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.sessions.service:owner' WHERE policy_ref = 'bee.sessions:owner';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.sessions.binding:threads_journal' WHERE policy_ref = 'bee.sessions:threads_journal';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.sessions.env:threads_journal_ref' WHERE policy_ref = 'bee.sessions:threads_journal_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.settings.app:build_info' WHERE policy_ref = 'bee.settings:build_info';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.sync.binding:admit' WHERE policy_ref = 'bee.sync.hive:admit';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.sync.values:bounds' WHERE policy_ref = 'bee.sync:bounds';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.sync.values:canonical' WHERE policy_ref = 'bee.sync:canonical';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.sync.env:database_ref' WHERE policy_ref = 'bee.sync:database_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.sync.env:db' WHERE policy_ref = 'bee.sync:db';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.sync.env:db_path' WHERE policy_ref = 'bee.sync:db_path';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.sync.env:environment' WHERE policy_ref = 'bee.sync:environment';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.sync.env:exports_ref' WHERE policy_ref = 'bee.sync:exports_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.sync.env:resources' WHERE policy_ref = 'bee.sync:resources';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.sync.values:version' WHERE policy_ref = 'bee.sync:version';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:append' WHERE policy_ref = 'bee.threads.approvals:append';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:cancel_intent' WHERE policy_ref = 'bee.threads.carrier:cancel_intent';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:cancel_status' WHERE policy_ref = 'bee.threads.carrier:cancel_status';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:checkpoint' WHERE policy_ref = 'bee.threads.carrier:checkpoint';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:claim' WHERE policy_ref = 'bee.threads.carrier:claim';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:commit' WHERE policy_ref = 'bee.threads.carrier:commit';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:ack' WHERE policy_ref = 'bee.threads.delivery:ack';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:ack_page' WHERE policy_ref = 'bee.threads.delivery:ack_page';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:delivery_claim' WHERE policy_ref = 'bee.threads.delivery:claim';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:close_subscription' WHERE policy_ref = 'bee.threads.delivery:close_subscription';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:dispatch' WHERE policy_ref = 'bee.threads.delivery:dispatch';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:expire' WHERE policy_ref = 'bee.threads.delivery:expire';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:forget_subscription' WHERE policy_ref = 'bee.threads.delivery:forget_subscription';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:page' WHERE policy_ref = 'bee.threads.delivery:page';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:reconcile' WHERE policy_ref = 'bee.threads.delivery:reconcile';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:release' WHERE policy_ref = 'bee.threads.delivery:release';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:resume' WHERE policy_ref = 'bee.threads.delivery:resume';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:subscribe' WHERE policy_ref = 'bee.threads.delivery:subscribe';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:unsubscribe' WHERE policy_ref = 'bee.threads.delivery:unsubscribe';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:wait' WHERE policy_ref = 'bee.threads.delivery:wait';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.service:waiter' WHERE policy_ref = 'bee.threads.delivery:waiter';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.service:waiter_service' WHERE policy_ref = 'bee.threads.delivery:waiter_service';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:watch' WHERE policy_ref = 'bee.threads.delivery:watch';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:recap_read' WHERE policy_ref = 'bee.threads.projection:recap_read';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:recap_rebuild' WHERE policy_ref = 'bee.threads.projection:recap_rebuild';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:recap_update' WHERE policy_ref = 'bee.threads.projection:recap_update';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:status_read' WHERE policy_ref = 'bee.threads.projection:status_read';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:status_rebuild' WHERE policy_ref = 'bee.threads.projection:status_rebuild';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:status_update' WHERE policy_ref = 'bee.threads.projection:status_update';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads:record_types' WHERE policy_ref = 'bee.threads.records:types';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:admit_action' WHERE policy_ref = 'bee.threads.service:admit_action';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:close' WHERE policy_ref = 'bee.threads.service:close';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:create' WHERE policy_ref = 'bee.threads.service:create';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:end_turn' WHERE policy_ref = 'bee.threads.service:end_turn';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:feed_read' WHERE policy_ref = 'bee.threads.service:feed_read';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:fence_app' WHERE policy_ref = 'bee.threads.service:fence_app';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:get' WHERE policy_ref = 'bee.threads.service:get';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:inbox_accept' WHERE policy_ref = 'bee.threads.service:inbox_accept';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:inbox_ack' WHERE policy_ref = 'bee.threads.service:inbox_ack';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:inbox_describe' WHERE policy_ref = 'bee.threads.service:inbox_describe';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:inbox_list' WHERE policy_ref = 'bee.threads.service:inbox_list';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:inbox_offer' WHERE policy_ref = 'bee.threads.service:inbox_offer';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:inbox_outbox_claim' WHERE policy_ref = 'bee.threads.service:inbox_outbox_claim';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:inbox_outbox_settle' WHERE policy_ref = 'bee.threads.service:inbox_outbox_settle';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:inbox_reply' WHERE policy_ref = 'bee.threads.service:inbox_reply';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:inbox_resolve' WHERE policy_ref = 'bee.threads.service:inbox_resolve';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:inbox_send' WHERE policy_ref = 'bee.threads.service:inbox_send';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:inbox_transport' WHERE policy_ref = 'bee.threads.service:inbox_transport';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:join' WHERE policy_ref = 'bee.threads.service:join';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:leave' WHERE policy_ref = 'bee.threads.service:leave';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:list' WHERE policy_ref = 'bee.threads.service:list';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:list_workspace' WHERE policy_ref = 'bee.threads.service:list_workspace';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:notify' WHERE policy_ref = 'bee.threads.service:notify';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:operation_describe' WHERE policy_ref = 'bee.threads.service:operation_describe';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:operation_lookup' WHERE policy_ref = 'bee.threads.service:operation_lookup';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:prepare_attempt' WHERE policy_ref = 'bee.threads.service:prepare_attempt';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:read_after' WHERE policy_ref = 'bee.threads.service:read_after';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:receipt' WHERE policy_ref = 'bee.threads.service:receipt';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:record' WHERE policy_ref = 'bee.threads.service:record';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:register_app_alias' WHERE policy_ref = 'bee.threads.service:register_app_alias';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:request_turn' WHERE policy_ref = 'bee.threads.service:request_turn';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:retire_app_alias' WHERE policy_ref = 'bee.threads.service:retire_app_alias';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:send' WHERE policy_ref = 'bee.threads.service:send';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:send_status' WHERE policy_ref = 'bee.threads.service:send_status';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:session_attach' WHERE policy_ref = 'bee.threads.service:session_attach';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:session_create' WHERE policy_ref = 'bee.threads.service:session_create';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:session_describe' WHERE policy_ref = 'bee.threads.service:session_describe';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:session_scan' WHERE policy_ref = 'bee.threads.service:session_scan';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:session_transition' WHERE policy_ref = 'bee.threads.service:session_transition';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:start_attempt' WHERE policy_ref = 'bee.threads.service:start_attempt';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:turn_accept' WHERE policy_ref = 'bee.threads.service:turn_accept';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:turn_observation' WHERE policy_ref = 'bee.threads.service:turn_observation';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:turn_pull' WHERE policy_ref = 'bee.threads.service:turn_pull';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:turn_recover' WHERE policy_ref = 'bee.threads.service:turn_recover';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:turn_reserve' WHERE policy_ref = 'bee.threads.service:turn_reserve';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads:types' WHERE policy_ref = 'bee.threads.service:types';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:work_cancel' WHERE policy_ref = 'bee.threads.service:work_cancel';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:work_describe' WHERE policy_ref = 'bee.threads.service:work_describe';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:work_history' WHERE policy_ref = 'bee.threads.service:work_history';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:work_scan' WHERE policy_ref = 'bee.threads.service:work_scan';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:work_send' WHERE policy_ref = 'bee.threads.service:work_send';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:work_settle' WHERE policy_ref = 'bee.threads.service:work_settle';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:work_uncertain' WHERE policy_ref = 'bee.threads.service:work_uncertain';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.timeline.security:client_policy' WHERE policy_ref = 'bee.threads.timeline:client_policy';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:approvals_local' WHERE policy_ref = 'bee.threads:approvals_local';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:authority_local' WHERE policy_ref = 'bee.threads:authority_local';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:capabilities' WHERE policy_ref = 'bee.threads:capabilities';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:capabilities_report' WHERE policy_ref = 'bee.threads:capabilities_report';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:carrier_local' WHERE policy_ref = 'bee.threads:carrier_local';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.env:database_path' WHERE policy_ref = 'bee.threads:database_path';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.env:database_ref' WHERE policy_ref = 'bee.threads:database_ref';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.env:db' WHERE policy_ref = 'bee.threads:db';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:delivery_local' WHERE policy_ref = 'bee.threads:delivery_local';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.env:environment' WHERE policy_ref = 'bee.threads:environment';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:journal_local' WHERE policy_ref = 'bee.threads:journal_local';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:lifecycle_local' WHERE policy_ref = 'bee.threads:lifecycle_local';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.service:owner' WHERE policy_ref = 'bee.threads:owner';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.service:owner_service' WHERE policy_ref = 'bee.threads:owner_service';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.binding:projection_local' WHERE policy_ref = 'bee.threads:projection_local';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.env:resources' WHERE policy_ref = 'bee.threads:resources';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.workspace.manager.security:client_policy' WHERE policy_ref = 'bee.workspace.manager:client_policy';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.security.approvals:approver_policies' WHERE policy_ref = 'bee:approver_policies';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.security.capability:capability_catalog' WHERE policy_ref = 'bee:capability_catalog';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.protocol:clock' WHERE policy_ref = 'bee:clock';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.env:docs_corpus' WHERE policy_ref = 'bee:docs_corpus';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.api:gateway_endpoint' WHERE policy_ref = 'bee:gateway_endpoint';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.service:gateway_installation_service' WHERE policy_ref = 'bee:gateway_installation_service';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.api:gateway_listener' WHERE policy_ref = 'bee:gateway_listener';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.api:gateway_mcp' WHERE policy_ref = 'bee:gateway_mcp';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.service:gateway_publication_service' WHERE policy_ref = 'bee:gateway_publication_service';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.api:gateway_ready' WHERE policy_ref = 'bee:gateway_ready';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.api:gateway_router' WHERE policy_ref = 'bee:gateway_router';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.binding:gateway_workspace_extension' WHERE policy_ref = 'bee:gateway_workspace_extension';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gov.service:gov_recovery_service' WHERE policy_ref = 'bee:gov_recovery_service';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.supervisor:hive_operation_adapters' WHERE policy_ref = 'bee:hive_operation_adapters';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hub.publication:hub_publication' WHERE policy_ref = 'bee:hub_publication';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.env:module_installation' WHERE policy_ref = 'bee:module_installation';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.gateway.env:module_publication' WHERE policy_ref = 'bee:module_publication';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.security.gov:protected_kernel' WHERE policy_ref = 'bee:protected_kernel';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.sync.service:sync_distribution_service' WHERE policy_ref = 'bee:sync_distribution_service';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.sync.env:sync_exports' WHERE policy_ref = 'bee:sync_exports';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.threads.service:thread_outbox_pump_service' WHERE policy_ref = 'bee:thread_outbox_pump_service';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.placement.native.env:workdir_preparers' WHERE policy_ref = 'bee:workdir_preparers';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.launch.service:workspace_hosts' WHERE policy_ref = 'bee:workspace_hosts';



]]
local HIVE_IDENTITY_VALUES = [[
    (1, '"bee.hive.service:inbox_sender"', '"bee.hive.binding:inbox_sender"'),
    (2, '"bee.hive.service:replica_sender"', '"bee.hive.binding:replica_sender"'),
    (3, '"bee.hive.supervisor:peers"', '"bee.hive.types:peers"'),
    (4, '"bee.hive.supervisor:registration"', '"bee.hive.types:registration"'),
    (5, '"bee.hive.supervisor:enrollment"', '"bee.hive.types:enrollment"'),
    (6, '"bee.hive.supervisor:invites"', '"bee.hive.types:invites"'),
    (7, '"bee.hive.supervisor:admission"', '"bee.hive.binding:admission"'),
    (8, '"bee.hive.supervisor:main"', '"bee.hive.service:supervisor"'),
    (9, '"bee.hive.supervisor:owner_stop"', '"bee.hive.types:owner_stop"'),
    (10, '"bee.hive.supervisor:workspace_commands"', '"bee.hive.types:workspace_commands"'),
    (11, '"bee.hive.supervisor:workspace_command"', '"bee.hive.binding:workspace_command"'),
    (12, '"bee.hive.supervisor:advertise"', '"bee.hive.binding:advertise"'),
    (13, '"bee.hive.supervisor:audiences"', '"bee.hive.types:audiences"'),
    (14, '"bee.hive.supervisor:policy_admission"', '"bee.hive.binding:policy_admission"'),
    (15, '"bee.hive.supervisor:admit_policy"', '"bee.hive.binding:admit_policy"'),
    (16, '"bee.hive.supervisor:adapters"', '"bee.hive.types:adapters"'),
    (17, '"bee.hive.supervisor:dispatch"', '"bee.hive.binding:dispatch"'),
    (18, '"bee.hive.supervisor:execute"', '"bee.hive.binding:execute"'),
    (19, '"bee.hive.api:workspaces"', '"bee.hive.binding:workspaces"'),
    (20, '"bee.hive.api:workspaces_page"', '"bee.hive.types:workspaces_page"'),
    (21, '"bee.hive.workspace:workspace_query"', '"bee.hive.types:workspace_query"'),
    (22, '"bee.hive.desktop:command"', '"bee.hive.service:display_command"'),
    (23, '"bee.hive.desktop:viewer"', '"bee.hive.service:viewer"')]]
local HIVE_REFERENCES_SQL = [[
UPDATE bee_gateway_surfaces SET surface_json = (
  WITH RECURSIVE identity_moves(position, prior, current) AS (VALUES
]] .. HIVE_IDENTITY_VALUES .. [[),
  rewritten(position, value) AS (
    SELECT 0, surface_json
    UNION ALL
    SELECT identity_moves.position, replace(rewritten.value, identity_moves.prior, identity_moves.current)
    FROM rewritten JOIN identity_moves ON identity_moves.position = rewritten.position + 1
  )
  SELECT value FROM rewritten ORDER BY position DESC LIMIT 1
) WHERE json_valid(surface_json) AND instr(surface_json, 'bee.hive') > 0;
UPDATE bee_gateway_surfaces SET active_json = (
  WITH RECURSIVE identity_moves(position, prior, current) AS (VALUES
]] .. HIVE_IDENTITY_VALUES .. [[),
  rewritten(position, value) AS (
    SELECT 0, active_json
    UNION ALL
    SELECT identity_moves.position, replace(rewritten.value, identity_moves.prior, identity_moves.current)
    FROM rewritten JOIN identity_moves ON identity_moves.position = rewritten.position + 1
  )
  SELECT value FROM rewritten ORDER BY position DESC LIMIT 1
) WHERE json_valid(active_json) AND instr(active_json, 'bee.hive') > 0;
UPDATE bee_gateway_access_grants SET traits_json = (
  WITH RECURSIVE identity_moves(position, prior, current) AS (VALUES
]] .. HIVE_IDENTITY_VALUES .. [[),
  rewritten(position, value) AS (
    SELECT 0, traits_json
    UNION ALL
    SELECT identity_moves.position, replace(rewritten.value, identity_moves.prior, identity_moves.current)
    FROM rewritten JOIN identity_moves ON identity_moves.position = rewritten.position + 1
  )
  SELECT value FROM rewritten ORDER BY position DESC LIMIT 1
) WHERE json_valid(traits_json) AND instr(traits_json, 'bee.hive') > 0;
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.binding:inbox_sender' WHERE policy_ref = 'bee.hive.service:inbox_sender';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.binding:replica_sender' WHERE policy_ref = 'bee.hive.service:replica_sender';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.types:peers' WHERE policy_ref = 'bee.hive.supervisor:peers';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.types:registration' WHERE policy_ref = 'bee.hive.supervisor:registration';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.types:enrollment' WHERE policy_ref = 'bee.hive.supervisor:enrollment';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.types:invites' WHERE policy_ref = 'bee.hive.supervisor:invites';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.binding:admission' WHERE policy_ref = 'bee.hive.supervisor:admission';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.service:supervisor' WHERE policy_ref = 'bee.hive.supervisor:main';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.types:owner_stop' WHERE policy_ref = 'bee.hive.supervisor:owner_stop';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.types:workspace_commands' WHERE policy_ref = 'bee.hive.supervisor:workspace_commands';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.binding:workspace_command' WHERE policy_ref = 'bee.hive.supervisor:workspace_command';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.binding:advertise' WHERE policy_ref = 'bee.hive.supervisor:advertise';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.types:audiences' WHERE policy_ref = 'bee.hive.supervisor:audiences';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.binding:policy_admission' WHERE policy_ref = 'bee.hive.supervisor:policy_admission';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.binding:admit_policy' WHERE policy_ref = 'bee.hive.supervisor:admit_policy';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.types:adapters' WHERE policy_ref = 'bee.hive.supervisor:adapters';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.binding:dispatch' WHERE policy_ref = 'bee.hive.supervisor:dispatch';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.binding:execute' WHERE policy_ref = 'bee.hive.supervisor:execute';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.binding:workspaces' WHERE policy_ref = 'bee.hive.api:workspaces';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.types:workspaces_page' WHERE policy_ref = 'bee.hive.api:workspaces_page';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.types:workspace_query' WHERE policy_ref = 'bee.hive.workspace:workspace_query';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.service:display_command' WHERE policy_ref = 'bee.hive.desktop:command';
UPDATE bee_gateway_bindings SET policy_ref = 'bee.hive.service:viewer' WHERE policy_ref = 'bee.hive.desktop:viewer';
UPDATE bee_gateway_surfaces SET surface_json = (
  WITH RECURSIVE owner_paths(position, path) AS (
    SELECT row_number() OVER (ORDER BY leaf.fullkey), leaf.fullkey
    FROM json_tree(surface_json) leaf JOIN json_tree(surface_json) owner ON leaf.parent = owner.id
    WHERE owner.key = 'owner_ref' AND leaf.key = 'service_id'
      AND leaf.value = 'bee.hive.api'
  ), rewritten(position, value) AS (
    SELECT 0, surface_json
    UNION ALL
    SELECT owner_paths.position, json_set(rewritten.value, owner_paths.path, 'bee.hive.binding')
    FROM rewritten JOIN owner_paths ON owner_paths.position = rewritten.position + 1
  )
  SELECT value FROM rewritten ORDER BY position DESC LIMIT 1
) WHERE json_valid(surface_json) AND instr(surface_json, 'bee.hive.api') > 0;
UPDATE bee_gateway_surfaces SET active_json = (
  WITH RECURSIVE owner_paths(position, path) AS (
    SELECT row_number() OVER (ORDER BY leaf.fullkey), leaf.fullkey
    FROM json_tree(active_json) leaf JOIN json_tree(active_json) owner ON leaf.parent = owner.id
    WHERE owner.key = 'owner_ref' AND leaf.key = 'service_id'
      AND leaf.value = 'bee.hive.api'
  ), rewritten(position, value) AS (
    SELECT 0, active_json
    UNION ALL
    SELECT owner_paths.position, json_set(rewritten.value, owner_paths.path, 'bee.hive.binding')
    FROM rewritten JOIN owner_paths ON owner_paths.position = rewritten.position + 1
  )
  SELECT value FROM rewritten ORDER BY position DESC LIMIT 1
) WHERE json_valid(active_json) AND instr(active_json, 'bee.hive.api') > 0;
UPDATE bee_gateway_access_grants SET traits_json = (
  WITH RECURSIVE owner_paths(position, path) AS (
    SELECT row_number() OVER (ORDER BY leaf.fullkey), leaf.fullkey
    FROM json_tree(traits_json) leaf JOIN json_tree(traits_json) owner ON leaf.parent = owner.id
    WHERE owner.key = 'owner_ref' AND leaf.key = 'service_id'
      AND leaf.value = 'bee.hive.api'
  ), rewritten(position, value) AS (
    SELECT 0, traits_json
    UNION ALL
    SELECT owner_paths.position, json_set(rewritten.value, owner_paths.path, 'bee.hive.binding')
    FROM rewritten JOIN owner_paths ON owner_paths.position = rewritten.position + 1
  )
  SELECT value FROM rewritten ORDER BY position DESC LIMIT 1
) WHERE json_valid(traits_json) AND instr(traits_json, 'bee.hive.api') > 0;

]]
local DESKTOP_REFERENCES_SQL = [[
UPDATE bee_gateway_surfaces SET surface_json = replace(surface_json, '"bee.session:main"', '"bee.desktop.service:main"')
WHERE json_valid(surface_json) AND instr(surface_json, '"bee.session:main"') > 0;
UPDATE bee_gateway_surfaces SET active_json = replace(active_json, '"bee.session:main"', '"bee.desktop.service:main"')
WHERE json_valid(active_json) AND instr(active_json, '"bee.session:main"') > 0;
UPDATE bee_gateway_access_grants SET traits_json = replace(traits_json, '"bee.session:main"', '"bee.desktop.service:main"')
WHERE json_valid(traits_json) AND instr(traits_json, '"bee.session:main"') > 0;
UPDATE bee_gateway_bindings SET policy_ref = 'bee.desktop.service:main' WHERE policy_ref = 'bee.session:main';
]]
function M.all(): {Migration}
    return {{id = 1, name = "gateway", sql = GATEWAY_SQL, rebuild = false}, {id = 2, name = "drain_deadline", sql = DRAIN_SQL, rebuild = false},
        {id = 3, name = "credentials", sql = CREDENTIALS_SQL, rebuild = true}, {id = 4, name = "materialization", sql = MATERIALIZATION_SQL, rebuild = false},
        {id = 5, name = "hooks", sql = HOOKS_SQL, rebuild = true}, {id = 6, name = "intake", sql = INTAKE_SQL, rebuild = true},
        {id = 7, name = "seal", sql = SEAL_SQL, rebuild = false},
        {id = 8, name = "native_listener", sql = NATIVE_LISTENER_SQL, rebuild = false},
        {id = 9, name = "binding_surface", sql = SURFACE_SQL, rebuild = false},
        {id = 10, name = "access_grants", sql = ACCESS_SQL, rebuild = false},
        {id = 11, name = "binding_policy", sql = POLICY_SQL, rebuild = false},
        {id = 12, name = "binding_origin_view", sql = ORIGIN_VIEW_SQL, rebuild = false},
        {id = 13, name = "workspace_sessions", sql = WORKSPACE_SESSIONS_SQL, rebuild = false},
        {id = 14, name = "session_names", sql = SESSION_NAMES_SQL, rebuild = false},
        {id = 15, name = "app_sdk_references", sql = APP_SDK_SQL, rebuild = false},
        {id = 16, name = "layout_registry_references", historical_sql = {ORIGINAL_SQL_16}, sql = LAYOUT_REFERENCES_SQL, rebuild = false},
        {id = 17, name = "root_namespace_references", sql = ROOT_REFERENCES_SQL, rebuild = false},
        {id = 18, name = "telemetry_owner_reference_repair", sql = TELEMETRY_OWNER_REPAIR_SQL, rebuild = false},
        {id = 19, name = "desktop_projection_references", sql = DESKTOP_REFERENCES_SQL, rebuild = false},
        {id = 20, name = "hive_component_references", sql = HIVE_REFERENCES_SQL, rebuild = false}}
end
return M
