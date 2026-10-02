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
        {id = 17, name = "telemetry_owner_reference_repair", sql = TELEMETRY_OWNER_REPAIR_SQL, rebuild = false}}
end
return M
