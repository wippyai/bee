local M = {}
type Migration = {id: integer, name: string, sql: string, rebuild: boolean}
local ATTEMPTS_SQL = [[
CREATE TABLE bee_placement_attempts (
    attempt_id TEXT PRIMARY KEY,
    owner_id TEXT NOT NULL,
    owner_incarnation INTEGER NOT NULL CHECK (owner_incarnation > 0),
    action_id TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    request_digest TEXT NOT NULL,
    request_json TEXT NOT NULL,
    grants_json TEXT,
    execution_state TEXT NOT NULL CHECK (execution_state IN ('intended', 'starting', 'running', 'stopping', 'exited', 'uncertain')),
    cleanup_state TEXT NOT NULL CHECK (cleanup_state IN ('pending', 'complete', 'uncertain')),
    capability TEXT NOT NULL CHECK (capability IN ('direct_process', 'process_group', 'contained_tree')),
    required_cleanup TEXT NOT NULL CHECK (required_cleanup IN ('direct_process', 'process_group', 'contained_tree')),
    exit_observation TEXT NOT NULL CHECK (exit_observation IN ('independent', 'eof_gated')),
    exit_source TEXT CHECK (exit_source IN ('runner', 'reconcile')),
    attachment_generation INTEGER NOT NULL DEFAULT 0 CHECK (attachment_generation >= 0),
    recipient TEXT,
    runner_pid TEXT,
    home_key TEXT,
    session_ref TEXT,
    pid INTEGER,
    pgid INTEGER,
    start_ticks INTEGER,
    boot_id TEXT,
    exit_code INTEGER,
    exit_signal INTEGER,
    evidence_count INTEGER NOT NULL DEFAULT 0 CHECK (evidence_count >= 0),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE (owner_id, idempotency_key)
);
CREATE INDEX bee_placement_attempts_action ON bee_placement_attempts (owner_id, action_id);
CREATE TABLE bee_placement_evidence (
    attempt_id TEXT NOT NULL REFERENCES bee_placement_attempts (attempt_id),
    sequence INTEGER NOT NULL CHECK (sequence > 0),
    at TEXT NOT NULL,
    kind TEXT NOT NULL,
    detail TEXT NOT NULL,
    PRIMARY KEY (attempt_id, sequence)
);
]]
-- Migration 2 adds the native terminal owner as an observed exit source.
-- Keep migration 1 immutable: placement stores may already have applied it.
local TERMINAL_EXIT_SQL = [[
CREATE TABLE bee_placement_attempts_next (
    attempt_id TEXT PRIMARY KEY,
    owner_id TEXT NOT NULL,
    owner_incarnation INTEGER NOT NULL CHECK (owner_incarnation > 0),
    action_id TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    request_digest TEXT NOT NULL,
    request_json TEXT NOT NULL,
    grants_json TEXT,
    execution_state TEXT NOT NULL CHECK (execution_state IN ('intended', 'starting', 'running', 'stopping', 'exited', 'uncertain')),
    cleanup_state TEXT NOT NULL CHECK (cleanup_state IN ('pending', 'complete', 'uncertain')),
    capability TEXT NOT NULL CHECK (capability IN ('direct_process', 'process_group', 'contained_tree')),
    required_cleanup TEXT NOT NULL CHECK (required_cleanup IN ('direct_process', 'process_group', 'contained_tree')),
    exit_observation TEXT NOT NULL CHECK (exit_observation IN ('independent', 'eof_gated')),
    exit_source TEXT CHECK (exit_source IN ('runner', 'reconcile', 'terminal')),
    attachment_generation INTEGER NOT NULL DEFAULT 0 CHECK (attachment_generation >= 0),
    recipient TEXT,
    runner_pid TEXT,
    home_key TEXT,
    session_ref TEXT,
    pid INTEGER,
    pgid INTEGER,
    start_ticks INTEGER,
    boot_id TEXT,
    exit_code INTEGER,
    exit_signal INTEGER,
    evidence_count INTEGER NOT NULL DEFAULT 0 CHECK (evidence_count >= 0),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE (owner_id, idempotency_key)
);
INSERT INTO bee_placement_attempts_next
    SELECT * FROM bee_placement_attempts;
DROP TABLE bee_placement_attempts;
ALTER TABLE bee_placement_attempts_next RENAME TO bee_placement_attempts;
CREATE INDEX bee_placement_attempts_action ON bee_placement_attempts (owner_id, action_id);
]]
local LAYOUT_REFERENCES_SQL = [[
UPDATE bee_placement_preparer_states SET binding_id = 'bee.git.worktree:binding' WHERE binding_id = 'bee.git_worktree:binding';
UPDATE bee_placement_preparer_states SET record_json = json_set(record_json, '$.binding_id', 'bee.git.worktree:binding') WHERE json_valid(record_json) AND json_extract(record_json, '$.binding_id') = 'bee.git_worktree:binding';
UPDATE bee_placement_preparer_states SET record_json = json_set(record_json, '$.plan', 'bee.git.worktree.binding:plan') WHERE json_valid(record_json) AND json_extract(record_json, '$.plan') = 'bee.git_worktree:plan';
UPDATE bee_placement_preparer_states SET record_json = json_set(record_json, '$.setup', 'bee.git.worktree.binding:setup') WHERE json_valid(record_json) AND json_extract(record_json, '$.setup') = 'bee.git_worktree:setup';
UPDATE bee_placement_preparer_states SET record_json = json_set(record_json, '$.cleanup', 'bee.git.worktree.binding:cleanup') WHERE json_valid(record_json) AND json_extract(record_json, '$.cleanup') = 'bee.git_worktree:cleanup';
UPDATE bee_placement_preparer_states SET record_json = json_set(record_json, '$.plan', 'bee.git.worktree.binding:plan') WHERE json_valid(record_json) AND json_extract(record_json, '$.plan') = 'bee.git.worktree:plan';
UPDATE bee_placement_preparer_states SET record_json = json_set(record_json, '$.setup', 'bee.git.worktree.binding:setup') WHERE json_valid(record_json) AND json_extract(record_json, '$.setup') = 'bee.git.worktree:setup';
UPDATE bee_placement_preparer_states SET record_json = json_set(record_json, '$.cleanup', 'bee.git.worktree.binding:cleanup') WHERE json_valid(record_json) AND json_extract(record_json, '$.cleanup') = 'bee.git.worktree:cleanup';
UPDATE bee_placement_evidence SET detail = 'bee.git.worktree:binding' WHERE kind IN ('workdir_preparer.cleaned', 'workdir_preparer.setup', 'workdir_preparer.state') AND detail = 'bee.git_worktree:binding';
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
UPDATE bee_placement_preparer_states SET binding_id = 'bee.git.worktree.binding:binding' WHERE binding_id = 'bee.git.worktree:binding';
UPDATE bee_placement_preparer_states SET record_json = json_set(record_json, '$.binding_id', 'bee.git.worktree.binding:binding') WHERE json_valid(record_json) AND json_extract(record_json, '$.binding_id') = 'bee.git.worktree:binding';
UPDATE bee_placement_evidence SET detail = 'bee.git.worktree.binding:binding' WHERE kind IN ('workdir_preparer.cleaned', 'workdir_preparer.setup', 'workdir_preparer.state') AND detail = 'bee.git.worktree:binding';
UPDATE bee_placement_attempts SET request_json = (
  WITH RECURSIVE identity_moves(position, prior, current) AS (VALUES
]] .. ROOT_IDENTITY_VALUES .. [[),
  rewritten(position, value) AS (
    SELECT 0, request_json
    UNION ALL
    SELECT identity_moves.position, replace(rewritten.value, identity_moves.prior, identity_moves.current)
    FROM rewritten JOIN identity_moves ON identity_moves.position = rewritten.position + 1
  )
  SELECT value FROM rewritten ORDER BY position DESC LIMIT 1
) WHERE json_valid(request_json) AND instr(request_json, 'bee') > 0;
UPDATE bee_placement_attempts SET grants_json = (
  WITH RECURSIVE identity_moves(position, prior, current) AS (VALUES
]] .. ROOT_IDENTITY_VALUES .. [[),
  rewritten(position, value) AS (
    SELECT 0, grants_json
    UNION ALL
    SELECT identity_moves.position, replace(rewritten.value, identity_moves.prior, identity_moves.current)
    FROM rewritten JOIN identity_moves ON identity_moves.position = rewritten.position + 1
  )
  SELECT value FROM rewritten ORDER BY position DESC LIMIT 1
) WHERE json_valid(grants_json) AND instr(grants_json, 'bee') > 0;
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
UPDATE bee_placement_attempts SET request_json = (
  WITH RECURSIVE identity_moves(position, prior, current) AS (VALUES
]] .. HIVE_IDENTITY_VALUES .. [[),
  rewritten(position, value) AS (
    SELECT 0, request_json
    UNION ALL
    SELECT identity_moves.position, replace(rewritten.value, identity_moves.prior, identity_moves.current)
    FROM rewritten JOIN identity_moves ON identity_moves.position = rewritten.position + 1
  )
  SELECT value FROM rewritten ORDER BY position DESC LIMIT 1
) WHERE json_valid(request_json) AND instr(request_json, 'bee.hive') > 0;
UPDATE bee_placement_attempts SET grants_json = (
  WITH RECURSIVE identity_moves(position, prior, current) AS (VALUES
]] .. HIVE_IDENTITY_VALUES .. [[),
  rewritten(position, value) AS (
    SELECT 0, grants_json
    UNION ALL
    SELECT identity_moves.position, replace(rewritten.value, identity_moves.prior, identity_moves.current)
    FROM rewritten JOIN identity_moves ON identity_moves.position = rewritten.position + 1
  )
  SELECT value FROM rewritten ORDER BY position DESC LIMIT 1
) WHERE json_valid(grants_json) AND instr(grants_json, 'bee.hive') > 0;
UPDATE bee_placement_attempts SET request_json = (
  WITH RECURSIVE owner_paths(position, path) AS (
    SELECT row_number() OVER (ORDER BY leaf.fullkey), leaf.fullkey
    FROM json_tree(request_json) leaf JOIN json_tree(request_json) owner ON leaf.parent = owner.id
    WHERE owner.key = 'owner_ref' AND leaf.key = 'service_id'
      AND leaf.value = 'bee.hive.api'
  ), rewritten(position, value) AS (
    SELECT 0, request_json
    UNION ALL
    SELECT owner_paths.position, json_set(rewritten.value, owner_paths.path, 'bee.hive.binding')
    FROM rewritten JOIN owner_paths ON owner_paths.position = rewritten.position + 1
  )
  SELECT value FROM rewritten ORDER BY position DESC LIMIT 1
) WHERE json_valid(request_json) AND instr(request_json, 'bee.hive.api') > 0;
UPDATE bee_placement_attempts SET grants_json = (
  WITH RECURSIVE owner_paths(position, path) AS (
    SELECT row_number() OVER (ORDER BY leaf.fullkey), leaf.fullkey
    FROM json_tree(grants_json) leaf JOIN json_tree(grants_json) owner ON leaf.parent = owner.id
    WHERE owner.key = 'owner_ref' AND leaf.key = 'service_id'
      AND leaf.value = 'bee.hive.api'
  ), rewritten(position, value) AS (
    SELECT 0, grants_json
    UNION ALL
    SELECT owner_paths.position, json_set(rewritten.value, owner_paths.path, 'bee.hive.binding')
    FROM rewritten JOIN owner_paths ON owner_paths.position = rewritten.position + 1
  )
  SELECT value FROM rewritten ORDER BY position DESC LIMIT 1
) WHERE json_valid(grants_json) AND instr(grants_json, 'bee.hive.api') > 0;

]]
local DESKTOP_REFERENCES_SQL = [[
UPDATE bee_placement_attempts SET request_json = replace(request_json, '"bee.session:main"', '"bee.desktop.service:main"')
WHERE json_valid(request_json) AND instr(request_json, '"bee.session:main"') > 0;
UPDATE bee_placement_attempts SET grants_json = replace(grants_json, '"bee.session:main"', '"bee.desktop.service:main"')
WHERE json_valid(grants_json) AND instr(grants_json, '"bee.session:main"') > 0;
UPDATE bee_placement_preparer_states SET record_json = replace(record_json, '"bee.session:main"', '"bee.desktop.service:main"')
WHERE json_valid(record_json) AND instr(record_json, '"bee.session:main"') > 0;
]]
local list: {Migration} = {
    {id = 1, name = "placement_attempts", sql = ATTEMPTS_SQL, rebuild = false},
    {id = 2, name = "terminal_exit_source", sql = TERMINAL_EXIT_SQL, rebuild = true},
    -- Placement implementations share one receipt store.  These nullable
    -- columns keep the native schema byte compatible while allowing a Docker
    -- owner to freeze its durable specification and observed identity.
    {id = 3, name = "placement_execution", sql = [[
ALTER TABLE bee_placement_attempts ADD COLUMN placement_kind TEXT CHECK (placement_kind IN ('native', 'docker'));
ALTER TABLE bee_placement_attempts ADD COLUMN placement_spec_json TEXT;
ALTER TABLE bee_placement_attempts ADD COLUMN placement_identity_json TEXT;
]], rebuild = false},
    -- A retained session may reuse provider-owned writable state, but immutable
    -- configuration composition bases stay bound to the bytes first admitted by
    -- the credential initializer. The digest is nonsecret and lives outside the
    -- provider-writable home.
    {id = 4, name = "retained_configuration_bases", sql = [[
CREATE TABLE bee_placement_session_files (
    owner_id TEXT NOT NULL,
    session_ref TEXT NOT NULL,
    path TEXT NOT NULL,
    digest TEXT NOT NULL CHECK (length(digest) = 64),
    created_at TEXT NOT NULL,
    PRIMARY KEY (owner_id, session_ref, path)
);
]], rebuild = false},
    -- A workdir preparer's ownership state is durable recovery input; the
    -- evidence detail is bounded and cannot hold it whole.
    {id = 5, name = "workdir_preparer_states", sql = [[
CREATE TABLE bee_placement_preparer_states (
    attempt_id TEXT NOT NULL REFERENCES bee_placement_attempts (attempt_id),
    binding_id TEXT NOT NULL,
    position INTEGER NOT NULL CHECK (position > 0),
    record_json TEXT NOT NULL CHECK (length(record_json) <= 65536),
    created_at TEXT NOT NULL,
    PRIMARY KEY (attempt_id, binding_id)
);
]], rebuild = false},
    -- Only the placement service knows the attempt-bound authority carried
    -- with controls sent to a runner. It is kept outside the public attempt
    -- projection and is generated when the runner starts.
    {id = 6, name = "runner_authorities", sql = [[
CREATE TABLE bee_placement_runner_authorities (
    attempt_id TEXT PRIMARY KEY REFERENCES bee_placement_attempts (attempt_id),
    control_token TEXT NOT NULL UNIQUE
);
]], rebuild = false},
    -- Migration 5 introduced the full-state table after older versions had
    -- stored ownership JSON in bounded evidence details. Carry valid records
    -- forward and retain malformed JSON as an unresolved cleanup intent.
    {id = 7, name = "legacy_workdir_preparer_states", sql = [[
INSERT OR IGNORE INTO bee_placement_preparer_states
    (attempt_id, binding_id, position, record_json, created_at)
SELECT attempt_id,
    CASE WHEN json_valid(detail) THEN
        CASE WHEN json_type(detail, '$.binding_id') = 'text'
                  AND length(json_extract(detail, '$.binding_id')) BETWEEN 1 AND 256
            THEN json_extract(detail, '$.binding_id')
            ELSE 'legacy-unresolved-' || CAST(sequence AS TEXT)
        END
    ELSE 'legacy-unresolved-' || CAST(sequence AS TEXT)
    END,
    sequence, detail, at
FROM bee_placement_evidence
WHERE kind = 'workdir_preparer.state'
  AND substr(ltrim(detail), 1, 1) = '{';
]], rebuild = false},
    {id = 8, name = "layout_registry_references", sql = LAYOUT_REFERENCES_SQL, rebuild = false},
    {id = 9, name = "root_namespace_references", sql = ROOT_REFERENCES_SQL, rebuild = false},
    {id = 10, name = "desktop_projection_references", sql = DESKTOP_REFERENCES_SQL, rebuild = false},
    {id = 11, name = "supervised_startup", sql = [[

CREATE TABLE bee_placement_attempts_next (
    attempt_id TEXT PRIMARY KEY,
    owner_id TEXT NOT NULL,
    owner_incarnation INTEGER NOT NULL CHECK (owner_incarnation > 0),
    action_id TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    request_digest TEXT NOT NULL,
    request_json TEXT NOT NULL,
    grants_json TEXT,
    placement_kind TEXT,
    placement_spec_json TEXT,
    placement_identity_json TEXT,
    execution_state TEXT NOT NULL CHECK (execution_state IN ('intended', 'starting', 'running', 'stopping', 'exited', 'start_failed', 'uncertain')),
    cleanup_state TEXT NOT NULL CHECK (cleanup_state IN ('pending', 'complete', 'uncertain')),
    capability TEXT NOT NULL CHECK (capability IN ('direct_process', 'process_group', 'contained_tree')),
    required_cleanup TEXT NOT NULL CHECK (required_cleanup IN ('direct_process', 'process_group', 'contained_tree')),
    exit_observation TEXT NOT NULL CHECK (exit_observation IN ('independent', 'eof_gated')),
    exit_source TEXT CHECK (exit_source IN ('runner', 'reconcile', 'terminal')),
    attachment_generation INTEGER NOT NULL DEFAULT 0 CHECK (attachment_generation >= 0),
    recipient TEXT,
    runner_pid TEXT,
    home_key TEXT,
    session_ref TEXT,
    pid INTEGER,
    pgid INTEGER,
    start_ticks INTEGER,
    boot_id TEXT,
    exit_code INTEGER,
    exit_signal INTEGER,
    evidence_count INTEGER NOT NULL DEFAULT 0 CHECK (evidence_count >= 0),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE (owner_id, idempotency_key)
);
INSERT INTO bee_placement_attempts_next SELECT
 attempt_id, owner_id, owner_incarnation, action_id, idempotency_key, request_digest,
 json_remove(request_json, '$.timeouts.start_ms'), grants_json, placement_kind, placement_spec_json, placement_identity_json,
 CASE WHEN EXISTS (SELECT 1 FROM bee_placement_evidence e WHERE e.attempt_id = bee_placement_attempts.attempt_id AND e.kind = 'child.start_failed') AND exit_code IS NULL AND exit_signal IS NULL AND NOT EXISTS (SELECT 1 FROM bee_placement_evidence observed WHERE observed.attempt_id = bee_placement_attempts.attempt_id AND observed.kind IN ('child.exited', 'docker.exited', 'reconcile.absent')) THEN 'start_failed' ELSE execution_state END,
 cleanup_state, capability, required_cleanup, exit_observation,
 CASE WHEN EXISTS (SELECT 1 FROM bee_placement_evidence e WHERE e.attempt_id = bee_placement_attempts.attempt_id AND e.kind = 'child.start_failed') AND exit_code IS NULL AND exit_signal IS NULL AND NOT EXISTS (SELECT 1 FROM bee_placement_evidence observed WHERE observed.attempt_id = bee_placement_attempts.attempt_id AND observed.kind IN ('child.exited', 'docker.exited', 'reconcile.absent')) THEN NULL ELSE exit_source END,
 attachment_generation, recipient, runner_pid, home_key, session_ref, pid, pgid, start_ticks, boot_id, exit_code, exit_signal,
 evidence_count, created_at, updated_at FROM bee_placement_attempts;
DROP TABLE bee_placement_attempts;
ALTER TABLE bee_placement_attempts_next RENAME TO bee_placement_attempts;
CREATE INDEX bee_placement_attempts_action ON bee_placement_attempts (owner_id, action_id);
]], rebuild = true},
    {id = 12, name = "hive_component_references", sql = HIVE_REFERENCES_SQL, rebuild = false},
}
function M.all(): {Migration}
    return list
end
return M
