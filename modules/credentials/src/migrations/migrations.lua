-- MIT. The credential broker schema as an ordered ledger. No secret bytes
-- are stored: definitions hold references, projections hold bindings.
local M = {}
type Migration = {id: integer, name: string, sql: string, rebuild: boolean}
local CREDENTIALS_SQL = [[
CREATE TABLE bee_credential_definitions (
    workspace_id TEXT NOT NULL,
    name TEXT NOT NULL,
    definition_id TEXT NOT NULL UNIQUE,
    revision INTEGER NOT NULL CHECK (revision > 0),
    provider TEXT NOT NULL CHECK (provider IN ('claude', 'codex')),
    source_kind TEXT NOT NULL CHECK (source_kind IN ('env_variable')),
    source_ref TEXT NOT NULL,
    projection_kind TEXT NOT NULL CHECK (projection_kind IN ('environment')),
    destination TEXT NOT NULL,
    digest TEXT NOT NULL,
    owner_node TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (workspace_id, name)
);
CREATE TABLE bee_credential_epochs (
    workspace_id TEXT PRIMARY KEY,
    epoch INTEGER NOT NULL CHECK (epoch >= 0)
);
CREATE TABLE bee_credential_projections (
    projection_id TEXT PRIMARY KEY,
    workspace_id TEXT NOT NULL,
    name TEXT NOT NULL,
    definition_id TEXT NOT NULL,
    definition_revision INTEGER NOT NULL CHECK (definition_revision > 0),
    issuer_owner TEXT NOT NULL,
    issuer_incarnation INTEGER NOT NULL CHECK (issuer_incarnation > 0),
    subject TEXT NOT NULL,
    audience TEXT NOT NULL,
    attempt_id TEXT NOT NULL,
    profile_id TEXT NOT NULL,
    profile_digest TEXT NOT NULL,
    binding_digest TEXT NOT NULL,
    launch_policy_digest TEXT NOT NULL,
    provider TEXT NOT NULL,
    projection_kind TEXT NOT NULL,
    destination TEXT NOT NULL,
    materializer TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    materialization_generation INTEGER NOT NULL DEFAULT 0 CHECK (materialization_generation >= 0),
    expires_at TEXT NOT NULL,
    authorization_epoch INTEGER NOT NULL CHECK (authorization_epoch >= 0),
    revoked_at TEXT,
    created_at TEXT NOT NULL,
    UNIQUE (subject, idempotency_key)
);
CREATE INDEX bee_credential_projections_attempt ON bee_credential_projections (attempt_id);
CREATE TABLE bee_credential_generations (
    projection_id TEXT NOT NULL REFERENCES bee_credential_projections (projection_id),
    generation_key TEXT NOT NULL,
    generation INTEGER NOT NULL CHECK (generation > 0),
    materializer_actor TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (projection_id, generation_key)
);
]]
local FILE_SOURCES_SQL = [[
CREATE TABLE bee_credential_definitions_next (
    workspace_id TEXT NOT NULL,
    name TEXT NOT NULL,
    definition_id TEXT NOT NULL UNIQUE,
    revision INTEGER NOT NULL CHECK (revision > 0),
    provider TEXT NOT NULL CHECK (provider IN ('claude', 'codex')),
    source_kind TEXT NOT NULL CHECK (source_kind IN ('env_variable', 'fs_directory')),
    source_ref TEXT NOT NULL,
    projection_kind TEXT NOT NULL CHECK (projection_kind IN ('environment', 'file')),
    destination TEXT NOT NULL,
    digest TEXT NOT NULL,
    owner_node TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (workspace_id, name)
);
INSERT INTO bee_credential_definitions_next
    SELECT * FROM bee_credential_definitions;
DROP TABLE bee_credential_definitions;
ALTER TABLE bee_credential_definitions_next RENAME TO bee_credential_definitions;
]]
local DECLARED_PROVIDERS_SQL = [[
CREATE TABLE bee_credential_definitions_next (
    workspace_id TEXT NOT NULL,
    name TEXT NOT NULL,
    definition_id TEXT NOT NULL UNIQUE,
    revision INTEGER NOT NULL CHECK (revision > 0),
    provider TEXT NOT NULL CHECK (length(provider) BETWEEN 1 AND 160),
    source_kind TEXT NOT NULL CHECK (source_kind IN ('env_variable', 'fs_directory')),
    source_ref TEXT NOT NULL,
    projection_kind TEXT NOT NULL CHECK (projection_kind IN ('environment', 'file')),
    destination TEXT NOT NULL,
    digest TEXT NOT NULL,
    owner_node TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    optional INTEGER NOT NULL DEFAULT 0 CHECK (optional IN (0,1)),
    PRIMARY KEY (workspace_id, name)
);
INSERT INTO bee_credential_definitions_next SELECT * FROM bee_credential_definitions;
DROP TABLE bee_credential_definitions;
ALTER TABLE bee_credential_definitions_next RENAME TO bee_credential_definitions;
]]
-- These are the layouts used before provider declarations. Freeze them during
-- upgrade without consulting mutable registry entries or reading login bytes.
local FROZEN_FORMATS_SQL = [[
ALTER TABLE bee_credential_definitions ADD COLUMN format_json TEXT NOT NULL DEFAULT '';
ALTER TABLE bee_credential_projections ADD COLUMN format_json TEXT NOT NULL DEFAULT '';
UPDATE bee_credential_definitions SET format_json = CASE provider
    WHEN 'codex' THEN '{"schema_revision":"bee.credential-format@1","environment_destination":"OPENAI_API_KEY","file":{"path":".codex/auth.json","content_format":"json","initialize":[]}}'
    WHEN 'claude' THEN '{"schema_revision":"bee.credential-format@1","environment_destination":"ANTHROPIC_API_KEY","file":{"path":".claude/.credentials.json","content_format":"json","initialize":[{"path":".claude.json","content":"{\"hasCompletedOnboarding\":true}"}]}}'
    ELSE '' END;
UPDATE bee_credential_projections SET format_json = CASE provider
    WHEN 'codex' THEN '{"schema_revision":"bee.credential-format@1","environment_destination":"OPENAI_API_KEY","file":{"path":".codex/auth.json","content_format":"json","initialize":[]}}'
    WHEN 'claude' THEN '{"schema_revision":"bee.credential-format@1","environment_destination":"ANTHROPIC_API_KEY","file":{"path":".claude/.credentials.json","content_format":"json","initialize":[{"path":".claude.json","content":"{\"hasCompletedOnboarding\":true}"}]}}'
    ELSE '' END;
]]
local NODE_IDENTITY_SQL = [[
CREATE TABLE bee_credential_node_identity_migrations (
    source_node TEXT NOT NULL,
    destination_node TEXT NOT NULL,
    migrated_at TEXT NOT NULL,
    definition_count INTEGER NOT NULL CHECK (definition_count >= 0),
    projection_count INTEGER NOT NULL CHECK (projection_count >= 0),
    PRIMARY KEY (source_node, destination_node),
    CHECK (source_node <> destination_node)
);
]]
local ROOT_REFERENCES_SQL = [[
UPDATE bee_credential_definitions SET source_ref = 'bee.approvals.inbox.app:client' WHERE source_ref = 'bee.approvals.inbox:client';
UPDATE bee_credential_definitions SET source_ref = 'bee.approvals.inbox.security:client_policy' WHERE source_ref = 'bee.approvals.inbox:client_policy';
UPDATE bee_credential_definitions SET source_ref = 'bee.approvals.inbox.app:source_config' WHERE source_ref = 'bee.approvals.inbox:source_config';
UPDATE bee_credential_definitions SET source_ref = 'bee.approvals.inbox.app:sources' WHERE source_ref = 'bee.approvals.inbox:sources';
UPDATE bee_credential_definitions SET source_ref = 'bee.approvals.inbox.app:workspaces' WHERE source_ref = 'bee.approvals.inbox:workspaces';
UPDATE bee_credential_definitions SET source_ref = 'bee.approvals.env:database_ref' WHERE source_ref = 'bee.approvals:database_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.approvals.env:db' WHERE source_ref = 'bee.approvals:db';
UPDATE bee_credential_definitions SET source_ref = 'bee.approvals.env:db_path' WHERE source_ref = 'bee.approvals:db_path';
UPDATE bee_credential_definitions SET source_ref = 'bee.approvals.env:environment' WHERE source_ref = 'bee.approvals:environment';
UPDATE bee_credential_definitions SET source_ref = 'bee.approvals.migrations:identity_migration' WHERE source_ref = 'bee.approvals:identity_migration';
UPDATE bee_credential_definitions SET source_ref = 'bee.approvals.binding:local' WHERE source_ref = 'bee.approvals:local';
UPDATE bee_credential_definitions SET source_ref = 'bee.approvals.env:node_identity_migration_source' WHERE source_ref = 'bee.approvals:node_identity_migration_source';
UPDATE bee_credential_definitions SET source_ref = 'bee.approvals.env:policies_ref' WHERE source_ref = 'bee.approvals:policies_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.approvals.env:resources' WHERE source_ref = 'bee.approvals:resources';
UPDATE bee_credential_definitions SET source_ref = 'bee.approvals.service:runtime_lease' WHERE source_ref = 'bee.approvals:runtime_lease';
UPDATE bee_credential_definitions SET source_ref = 'bee.approvals.service:service' WHERE source_ref = 'bee.approvals:service';
UPDATE bee_credential_definitions SET source_ref = 'bee.console.app:command' WHERE source_ref = 'bee.console:command';
UPDATE bee_credential_definitions SET source_ref = 'bee.console.security:command_policy' WHERE source_ref = 'bee.console:command_policy';
UPDATE bee_credential_definitions SET source_ref = 'bee.console.env:environment' WHERE source_ref = 'bee.console:environment';
UPDATE bee_credential_definitions SET source_ref = 'bee.console.env:executor' WHERE source_ref = 'bee.console:executor';
UPDATE bee_credential_definitions SET source_ref = 'bee.console.security:executor_policy' WHERE source_ref = 'bee.console:executor_policy';
UPDATE bee_credential_definitions SET source_ref = 'bee.console.env:home' WHERE source_ref = 'bee.console:home';
UPDATE bee_credential_definitions SET source_ref = 'bee.console.env:lang' WHERE source_ref = 'bee.console:lang';
UPDATE bee_credential_definitions SET source_ref = 'bee.console.env:path' WHERE source_ref = 'bee.console:path';
UPDATE bee_credential_definitions SET source_ref = 'bee.console.env:user' WHERE source_ref = 'bee.console:user';
UPDATE bee_credential_definitions SET source_ref = 'bee.credentials.env:credential_sources' WHERE source_ref = 'bee.credentials:credential_sources';
UPDATE bee_credential_definitions SET source_ref = 'bee.credentials.env:database_ref' WHERE source_ref = 'bee.credentials:database_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.credentials.env:db' WHERE source_ref = 'bee.credentials:db';
UPDATE bee_credential_definitions SET source_ref = 'bee.credentials.env:db_path' WHERE source_ref = 'bee.credentials:db_path';
UPDATE bee_credential_definitions SET source_ref = 'bee.credentials.env:environment' WHERE source_ref = 'bee.credentials:environment';
UPDATE bee_credential_definitions SET source_ref = 'bee.credentials.binding:local' WHERE source_ref = 'bee.credentials:local';
UPDATE bee_credential_definitions SET source_ref = 'bee.credentials.env:materializer_ref' WHERE source_ref = 'bee.credentials:materializer_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.credentials.env:node_identity_migration_source' WHERE source_ref = 'bee.credentials:node_identity_migration_source';
UPDATE bee_credential_definitions SET source_ref = 'bee.credentials.env:sources' WHERE source_ref = 'bee.credentials:sources';
UPDATE bee_credential_definitions SET source_ref = 'bee.credentials.env:sources_ref' WHERE source_ref = 'bee.credentials:sources_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.docs.binding:corpus' WHERE source_ref = 'bee.docs:corpus';
UPDATE bee_credential_definitions SET source_ref = 'bee.docs.env:corpus_ref' WHERE source_ref = 'bee.docs:corpus_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.docs.env:resources' WHERE source_ref = 'bee.docs:resources';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.agy.binding:binding' WHERE source_ref = 'bee.driver.agy:binding';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.agy.descriptor:command' WHERE source_ref = 'bee.driver.agy:command';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.agy.binding:configuration' WHERE source_ref = 'bee.driver.agy:configuration';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.agy.credentials:credential_format' WHERE source_ref = 'bee.driver.agy:credential_format';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.agy.profiles:default_window' WHERE source_ref = 'bee.driver.agy:default_window';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.agy.env:executable' WHERE source_ref = 'bee.driver.agy:executable';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.agy.binding:launch' WHERE source_ref = 'bee.driver.agy:launch';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.agy.security:launch_policy_agy_batch' WHERE source_ref = 'bee.driver.agy:launch_policy_agy_batch';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.agy.security:launch_policy_agy_window' WHERE source_ref = 'bee.driver.agy:launch_policy_agy_window';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.agy.descriptor:locate' WHERE source_ref = 'bee.driver.agy:locate';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.agy.profiles:profiles' WHERE source_ref = 'bee.driver.agy:profiles';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.agy.binding:protocol' WHERE source_ref = 'bee.driver.agy:protocol';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.agy.profiles:research_batch' WHERE source_ref = 'bee.driver.agy:research_batch';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.claude.env:api_key' WHERE source_ref = 'bee.driver.claude:api_key';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.claude.binding:binding' WHERE source_ref = 'bee.driver.claude:binding';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.claude.descriptor:command' WHERE source_ref = 'bee.driver.claude:command';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.claude.env:config_home' WHERE source_ref = 'bee.driver.claude:config_home';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.claude.credentials:credential_format' WHERE source_ref = 'bee.driver.claude:credential_format';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.claude.profiles:default_window' WHERE source_ref = 'bee.driver.claude:default_window';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.claude.env:executable' WHERE source_ref = 'bee.driver.claude:executable';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.claude.binding:launch' WHERE source_ref = 'bee.driver.claude:launch';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.claude.security:launch_policy_claude_batch' WHERE source_ref = 'bee.driver.claude:launch_policy_claude_batch';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.claude.security:launch_policy_claude_window' WHERE source_ref = 'bee.driver.claude:launch_policy_claude_window';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.claude.descriptor:locate' WHERE source_ref = 'bee.driver.claude:locate';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.claude.permission:permission_adapter' WHERE source_ref = 'bee.driver.claude:permission_adapter';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.claude.profiles:profiles' WHERE source_ref = 'bee.driver.claude:profiles';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.claude.binding:protocol' WHERE source_ref = 'bee.driver.claude:protocol';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.claude.profiles:research_batch' WHERE source_ref = 'bee.driver.claude:research_batch';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.codex.binding:binding' WHERE source_ref = 'bee.driver.codex:binding';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.codex.descriptor:command' WHERE source_ref = 'bee.driver.codex:command';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.codex.env:config_home' WHERE source_ref = 'bee.driver.codex:config_home';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.codex.binding:configuration' WHERE source_ref = 'bee.driver.codex:configuration';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.codex.credentials:credential_format' WHERE source_ref = 'bee.driver.codex:credential_format';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.codex.descriptor:default_provider' WHERE source_ref = 'bee.driver.codex:default_provider';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.codex.profiles:default_window' WHERE source_ref = 'bee.driver.codex:default_window';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.codex.env:executable' WHERE source_ref = 'bee.driver.codex:executable';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.codex.binding:launch' WHERE source_ref = 'bee.driver.codex:launch';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.codex.security:launch_policy_codex_batch' WHERE source_ref = 'bee.driver.codex:launch_policy_codex_batch';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.codex.security:launch_policy_codex_named_batch' WHERE source_ref = 'bee.driver.codex:launch_policy_codex_named_batch';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.codex.security:launch_policy_codex_window' WHERE source_ref = 'bee.driver.codex:launch_policy_codex_window';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.codex.descriptor:locate' WHERE source_ref = 'bee.driver.codex:locate';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.codex.profiles:named_batch' WHERE source_ref = 'bee.driver.codex:named_batch';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.codex.profiles:profiles' WHERE source_ref = 'bee.driver.codex:profiles';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.codex.binding:protocol' WHERE source_ref = 'bee.driver.codex:protocol';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.codex.profiles:research_batch' WHERE source_ref = 'bee.driver.codex:research_batch';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.grok.binding:binding' WHERE source_ref = 'bee.driver.grok:binding';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.grok.descriptor:command' WHERE source_ref = 'bee.driver.grok:command';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.grok.binding:configuration' WHERE source_ref = 'bee.driver.grok:configuration';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.grok.credentials:credential_format' WHERE source_ref = 'bee.driver.grok:credential_format';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.grok.profiles:default_window' WHERE source_ref = 'bee.driver.grok:default_window';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.grok.env:executable' WHERE source_ref = 'bee.driver.grok:executable';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.grok.binding:launch' WHERE source_ref = 'bee.driver.grok:launch';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.grok.security:launch_policy_grok_batch' WHERE source_ref = 'bee.driver.grok:launch_policy_grok_batch';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.grok.security:launch_policy_grok_window' WHERE source_ref = 'bee.driver.grok:launch_policy_grok_window';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.grok.descriptor:locate' WHERE source_ref = 'bee.driver.grok:locate';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.grok.profiles:profiles' WHERE source_ref = 'bee.driver.grok:profiles';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.grok.binding:protocol' WHERE source_ref = 'bee.driver.grok:protocol';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.grok.profiles:research_batch' WHERE source_ref = 'bee.driver.grok:research_batch';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.muse.binding:binding' WHERE source_ref = 'bee.driver.muse:binding';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.muse.descriptor:command' WHERE source_ref = 'bee.driver.muse:command';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.muse.binding:configuration' WHERE source_ref = 'bee.driver.muse:configuration';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.muse.credentials:credential_format' WHERE source_ref = 'bee.driver.muse:credential_format';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.muse.profiles:default_window' WHERE source_ref = 'bee.driver.muse:default_window';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.muse.env:executable' WHERE source_ref = 'bee.driver.muse:executable';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.muse.binding:launch' WHERE source_ref = 'bee.driver.muse:launch';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.muse.security:launch_policy_muse_batch' WHERE source_ref = 'bee.driver.muse:launch_policy_muse_batch';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.muse.security:launch_policy_muse_window' WHERE source_ref = 'bee.driver.muse:launch_policy_muse_window';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.muse.descriptor:locate' WHERE source_ref = 'bee.driver.muse:locate';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.muse.profiles:profiles' WHERE source_ref = 'bee.driver.muse:profiles';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.muse.binding:protocol' WHERE source_ref = 'bee.driver.muse:protocol';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.muse.profiles:research_batch' WHERE source_ref = 'bee.driver.muse:research_batch';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.opencode.binding:binding' WHERE source_ref = 'bee.driver.opencode:binding';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.opencode.descriptor:command' WHERE source_ref = 'bee.driver.opencode:command';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.opencode.binding:configuration' WHERE source_ref = 'bee.driver.opencode:configuration';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.opencode.credentials:credential_format' WHERE source_ref = 'bee.driver.opencode:credential_format';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.opencode.profiles:default_window' WHERE source_ref = 'bee.driver.opencode:default_window';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.opencode.env:executable' WHERE source_ref = 'bee.driver.opencode:executable';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.opencode.binding:launch' WHERE source_ref = 'bee.driver.opencode:launch';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.opencode.security:launch_policy_opencode_batch' WHERE source_ref = 'bee.driver.opencode:launch_policy_opencode_batch';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.opencode.security:launch_policy_opencode_window' WHERE source_ref = 'bee.driver.opencode:launch_policy_opencode_window';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.opencode.descriptor:locate' WHERE source_ref = 'bee.driver.opencode:locate';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.opencode.profiles:profiles' WHERE source_ref = 'bee.driver.opencode:profiles';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.opencode.binding:protocol' WHERE source_ref = 'bee.driver.opencode:protocol';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.opencode.profiles:research_batch' WHERE source_ref = 'bee.driver.opencode:research_batch';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.wippy.binding:binding' WHERE source_ref = 'bee.driver.wippy:binding';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.wippy.binding:client' WHERE source_ref = 'bee.driver.wippy:client';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.wippy.env:host_config' WHERE source_ref = 'bee.driver.wippy:host_config';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.wippy.profiles:profiles' WHERE source_ref = 'bee.driver.wippy:profiles';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.wippy.binding:run' WHERE source_ref = 'bee.driver.wippy:run';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.wippy.service:runner' WHERE source_ref = 'bee.driver.wippy:runner';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.codec:codec_registry' WHERE source_ref = 'bee.driver:codec_registry';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.configuration:configuration' WHERE source_ref = 'bee.driver:configuration';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.descriptor:descriptor' WHERE source_ref = 'bee.driver:descriptor';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.profiles:instructions' WHERE source_ref = 'bee.driver:instructions';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.locate:locate' WHERE source_ref = 'bee.driver:locate';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.locate:login_evidence' WHERE source_ref = 'bee.driver:login_evidence';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.configuration:option_render' WHERE source_ref = 'bee.driver:option_render';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.permission:permission_request_hook' WHERE source_ref = 'bee.driver:permission_request_hook';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.profiles:preferences' WHERE source_ref = 'bee.driver:preferences';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.locate:probe_capture' WHERE source_ref = 'bee.driver:probe_capture';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.profiles:profile' WHERE source_ref = 'bee.driver:profile';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.profiles:profile_access' WHERE source_ref = 'bee.driver:profile_access';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.binding:resolver' WHERE source_ref = 'bee.driver:resolver';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.descriptor:schema_values' WHERE source_ref = 'bee.driver:schema_values';
UPDATE bee_credential_definitions SET source_ref = 'bee.driver.binding:universal' WHERE source_ref = 'bee.driver:universal';
UPDATE bee_credential_definitions SET source_ref = 'bee.files.app:gitignore' WHERE source_ref = 'bee.files:gitignore';
UPDATE bee_credential_definitions SET source_ref = 'bee.files.app:source' WHERE source_ref = 'bee.files:source';
UPDATE bee_credential_definitions SET source_ref = 'bee.files.app:syntax' WHERE source_ref = 'bee.files:syntax';
UPDATE bee_credential_definitions SET source_ref = 'bee.files.app:tree' WHERE source_ref = 'bee.files:tree';
UPDATE bee_credential_definitions SET source_ref = 'bee.files.env:workspace_root_ref' WHERE source_ref = 'bee.files:workspace_root_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.binding:address' WHERE source_ref = 'bee.gateway:address';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.api:address_value' WHERE source_ref = 'bee.gateway:address_value';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.env:approval_consume_policy_ref' WHERE source_ref = 'bee.gateway:approval_consume_policy_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.env:approval_request_policy_ref' WHERE source_ref = 'bee.gateway:approval_request_policy_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.catalog:catalog' WHERE source_ref = 'bee.gateway:catalog';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.env:configuration' WHERE source_ref = 'bee.gateway:configuration';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.catalog:context' WHERE source_ref = 'bee.gateway:context';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.env:database_ref' WHERE source_ref = 'bee.gateway:database_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.env:db' WHERE source_ref = 'bee.gateway:db';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.env:db_path' WHERE source_ref = 'bee.gateway:db_path';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.env:endpoint_ref' WHERE source_ref = 'bee.gateway:endpoint_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.env:environment' WHERE source_ref = 'bee.gateway:environment';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.env:hook_executable' WHERE source_ref = 'bee.gateway:hook_executable';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.hooks:hooks' WHERE source_ref = 'bee.gateway:hooks';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.env:install_configuration_ref' WHERE source_ref = 'bee.gateway:install_configuration_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.catalog:json_schema' WHERE source_ref = 'bee.gateway:json_schema';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.env:listener_ref' WHERE source_ref = 'bee.gateway:listener_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.api:mcp' WHERE source_ref = 'bee.gateway:mcp';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.catalog:profile_scope' WHERE source_ref = 'bee.gateway:profile_scope';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.env:publish_configuration_ref' WHERE source_ref = 'bee.gateway:publish_configuration_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.catalog:session_bundle' WHERE source_ref = 'bee.gateway:session_bundle';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.catalog:session_tools' WHERE source_ref = 'bee.gateway:session_tools';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.catalog:sessions' WHERE source_ref = 'bee.gateway:sessions';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.catalog:surface' WHERE source_ref = 'bee.gateway:surface';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.env:tool_application_open_policy_ref' WHERE source_ref = 'bee.gateway:tool_application_open_policy_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.env:tool_components_policy_ref' WHERE source_ref = 'bee.gateway:tool_components_policy_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.env:tool_delivery_policy_ref' WHERE source_ref = 'bee.gateway:tool_delivery_policy_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.env:tool_docs_policy_ref' WHERE source_ref = 'bee.gateway:tool_docs_policy_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.env:tool_hub_publish_policy_ref' WHERE source_ref = 'bee.gateway:tool_hub_publish_policy_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.env:tool_install_policy_ref' WHERE source_ref = 'bee.gateway:tool_install_policy_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.env:tool_message_policy_ref' WHERE source_ref = 'bee.gateway:tool_message_policy_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.env:tool_overlay_policy_ref' WHERE source_ref = 'bee.gateway:tool_overlay_policy_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.env:tool_publish_policy_ref' WHERE source_ref = 'bee.gateway:tool_publish_policy_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.env:tool_read_policy_ref' WHERE source_ref = 'bee.gateway:tool_read_policy_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.env:tool_session_policy_ref' WHERE source_ref = 'bee.gateway:tool_session_policy_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.git.worktree.binding:binding' WHERE source_ref = 'bee.git.worktree:binding';
UPDATE bee_credential_definitions SET source_ref = 'bee.git.worktree.binding:cleanup' WHERE source_ref = 'bee.git.worktree:cleanup';
UPDATE bee_credential_definitions SET source_ref = 'bee.git.worktree.env:executor_ref' WHERE source_ref = 'bee.git.worktree:executor_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.git.worktree.env:git_executor' WHERE source_ref = 'bee.git.worktree:git_executor';
UPDATE bee_credential_definitions SET source_ref = 'bee.git.worktree.binding:git_roots' WHERE source_ref = 'bee.git.worktree:git_roots';
UPDATE bee_credential_definitions SET source_ref = 'bee.git.worktree.env:host_files' WHERE source_ref = 'bee.git.worktree:host_files';
UPDATE bee_credential_definitions SET source_ref = 'bee.git.worktree.env:host_files_ref' WHERE source_ref = 'bee.git.worktree:host_files_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.git.worktree.binding:plan' WHERE source_ref = 'bee.git.worktree:plan';
UPDATE bee_credential_definitions SET source_ref = 'bee.git.worktree.binding:setup' WHERE source_ref = 'bee.git.worktree:setup';
UPDATE bee_credential_definitions SET source_ref = 'bee.git.worktree.binding:worktree' WHERE source_ref = 'bee.git.worktree:worktree';
UPDATE bee_credential_definitions SET source_ref = 'bee.git.worktree.security:worktree_policy' WHERE source_ref = 'bee.git.worktree:worktree_policy';
UPDATE bee_credential_definitions SET source_ref = 'bee.git.worktree.binding:binding' WHERE source_ref = 'bee.git_worktree:binding';
UPDATE bee_credential_definitions SET source_ref = 'bee.git.worktree.binding:cleanup' WHERE source_ref = 'bee.git_worktree:cleanup';
UPDATE bee_credential_definitions SET source_ref = 'bee.git.worktree:definition' WHERE source_ref = 'bee.git_worktree:definition';
UPDATE bee_credential_definitions SET source_ref = 'bee.git.worktree:dependency_driver' WHERE source_ref = 'bee.git_worktree:dependency_driver';
UPDATE bee_credential_definitions SET source_ref = 'bee.git.worktree:dependency_placement' WHERE source_ref = 'bee.git_worktree:dependency_placement';
UPDATE bee_credential_definitions SET source_ref = 'bee.git.worktree:dependency_threads' WHERE source_ref = 'bee.git_worktree:dependency_threads';
UPDATE bee_credential_definitions SET source_ref = 'bee.git.worktree.env:executor_ref' WHERE source_ref = 'bee.git_worktree:executor_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.git.worktree.env:git_executor' WHERE source_ref = 'bee.git_worktree:git_executor';
UPDATE bee_credential_definitions SET source_ref = 'bee.git.worktree.binding:git_roots' WHERE source_ref = 'bee.git_worktree:git_roots';
UPDATE bee_credential_definitions SET source_ref = 'bee.git.worktree.env:host_files' WHERE source_ref = 'bee.git_worktree:host_files';
UPDATE bee_credential_definitions SET source_ref = 'bee.git.worktree.env:host_files_ref' WHERE source_ref = 'bee.git_worktree:host_files_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.git.worktree.binding:plan' WHERE source_ref = 'bee.git_worktree:plan';
UPDATE bee_credential_definitions SET source_ref = 'bee.git.worktree:protected_namespace' WHERE source_ref = 'bee.git_worktree:protected_namespace';
UPDATE bee_credential_definitions SET source_ref = 'bee.git.worktree.binding:setup' WHERE source_ref = 'bee.git_worktree:setup';
UPDATE bee_credential_definitions SET source_ref = 'bee.git.worktree:target_executor' WHERE source_ref = 'bee.git_worktree:target_executor';
UPDATE bee_credential_definitions SET source_ref = 'bee.git.worktree:target_host_files' WHERE source_ref = 'bee.git_worktree:target_host_files';
UPDATE bee_credential_definitions SET source_ref = 'bee.git.worktree.binding:worktree' WHERE source_ref = 'bee.git_worktree:worktree';
UPDATE bee_credential_definitions SET source_ref = 'bee.git.worktree.security:worktree_policy' WHERE source_ref = 'bee.git_worktree:worktree_policy';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.overlays.security:client_policy' WHERE source_ref = 'bee.gov.overlays:client_policy';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.activation:activation_measure' WHERE source_ref = 'bee.gov:activation_measure';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.activation:activation_profile_decoder' WHERE source_ref = 'bee.gov:activation_profile_decoder';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.env:activation_profiles_ref' WHERE source_ref = 'bee.gov:activation_profiles_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.activation:application_admissions' WHERE source_ref = 'bee.gov:application_admissions';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.env:approval_consume_policy_ref' WHERE source_ref = 'bee.gov:approval_consume_policy_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.env:approval_request_policy_ref' WHERE source_ref = 'bee.gov:approval_request_policy_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.delivery:artifact' WHERE source_ref = 'bee.gov:artifact';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.delivery:candidate' WHERE source_ref = 'bee.gov:candidate';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.capability:capability_files' WHERE source_ref = 'bee.gov:capability_files';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.capability:capability_gateway' WHERE source_ref = 'bee.gov:capability_gateway';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.capability:capability_grants' WHERE source_ref = 'bee.gov:capability_grants';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.capability:capability_request' WHERE source_ref = 'bee.gov:capability_request';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.env:database_ref' WHERE source_ref = 'bee.gov:database_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.env:db' WHERE source_ref = 'bee.gov:db';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.env:db_path' WHERE source_ref = 'bee.gov:db_path';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.delivery:delivery' WHERE source_ref = 'bee.gov:delivery';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.binding:delivery_local' WHERE source_ref = 'bee.gov:delivery_local';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.delivery:delivery_protocol' WHERE source_ref = 'bee.gov:delivery_protocol';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.env:environment' WHERE source_ref = 'bee.gov:environment';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.activation:governed_application_admission' WHERE source_ref = 'bee.gov:governed_application_admission';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.activation:headless_revert' WHERE source_ref = 'bee.gov:headless_revert';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.delivery:hub_resolver' WHERE source_ref = 'bee.gov:hub_resolver';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.delivery:lease_model' WHERE source_ref = 'bee.gov:lease_model';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.activation:lists' WHERE source_ref = 'bee.gov:lists';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.delivery:materializer' WHERE source_ref = 'bee.gov:materializer';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.activation:migration_work' WHERE source_ref = 'bee.gov:migration_work';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.env:node_identity_migration_source' WHERE source_ref = 'bee.gov:node_identity_migration_source';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.binding:overlay_local' WHERE source_ref = 'bee.gov:overlay_local';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.delivery:overlay_resolver' WHERE source_ref = 'bee.gov:overlay_resolver';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.activation:preflight' WHERE source_ref = 'bee.gov:preflight';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.activation:protected_kernel' WHERE source_ref = 'bee.gov:protected_kernel';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.delivery:publication_profile_decoder' WHERE source_ref = 'bee.gov:publication_profile_decoder';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.env:publication_profiles_ref' WHERE source_ref = 'bee.gov:publication_profiles_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.delivery:resolver' WHERE source_ref = 'bee.gov:resolver';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.delivery:staging_resources' WHERE source_ref = 'bee.gov:staging_resources';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.activation:super_edit' WHERE source_ref = 'bee.gov:super_edit';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.workspace:workspace' WHERE source_ref = 'bee.gov:workspace';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.workspace:workspace_applications' WHERE source_ref = 'bee.gov:workspace_applications';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.env:workspace_folder_policy_ref' WHERE source_ref = 'bee.gov:workspace_folder_policy_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.env:workspace_folder_read_ref' WHERE source_ref = 'bee.gov:workspace_folder_read_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.workspace:workspace_protocol' WHERE source_ref = 'bee.gov:workspace_protocol';
UPDATE bee_credential_definitions SET source_ref = 'bee.harness.binding:capabilities' WHERE source_ref = 'bee.harness.carrier:capabilities';
UPDATE bee_credential_definitions SET source_ref = 'bee.harness.service:carrier' WHERE source_ref = 'bee.harness.carrier:process';
UPDATE bee_credential_definitions SET source_ref = 'bee.harness:types' WHERE source_ref = 'bee.harness.carrier:types';
UPDATE bee_credential_definitions SET source_ref = 'bee.harness.binding:admit' WHERE source_ref = 'bee.harness.launch:admit';
UPDATE bee_credential_definitions SET source_ref = 'bee.harness.binding:locate_probe' WHERE source_ref = 'bee.harness.launch:locate_probe';
UPDATE bee_credential_definitions SET source_ref = 'bee.harness.binding:present' WHERE source_ref = 'bee.harness.launch:present';
UPDATE bee_credential_definitions SET source_ref = 'bee.harness.binding:resolve' WHERE source_ref = 'bee.harness.launch:resolve';
UPDATE bee_credential_definitions SET source_ref = 'bee.harness.binding:setup' WHERE source_ref = 'bee.harness.launch:setup';
UPDATE bee_credential_definitions SET source_ref = 'bee.harness.binding:setup_backend' WHERE source_ref = 'bee.harness.launch:setup_backend';
UPDATE bee_credential_definitions SET source_ref = 'bee.harness.binding:start' WHERE source_ref = 'bee.harness.launch:start';
UPDATE bee_credential_definitions SET source_ref = 'bee.harness.binding:call' WHERE source_ref = 'bee.harness.profiles:call';
UPDATE bee_credential_definitions SET source_ref = 'bee.harness:profiles' WHERE source_ref = 'bee.harness.profiles:contract';
UPDATE bee_credential_definitions SET source_ref = 'bee.harness.binding:profiles_local' WHERE source_ref = 'bee.harness.profiles:local';
UPDATE bee_credential_definitions SET source_ref = 'bee.harness.env:carrier_host_ref' WHERE source_ref = 'bee.harness:carrier_host_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.harness.api:gateway_hook' WHERE source_ref = 'bee.harness:gateway_hook';
UPDATE bee_credential_definitions SET source_ref = 'bee.harness.api:gateway_hook_mcp' WHERE source_ref = 'bee.harness:gateway_hook_mcp';
UPDATE bee_credential_definitions SET source_ref = 'bee.harness.api:gateway_hook_status' WHERE source_ref = 'bee.harness:gateway_hook_status';
UPDATE bee_credential_definitions SET source_ref = 'bee.harness.launch:harness_activation' WHERE source_ref = 'bee.harness:harness_activation';
UPDATE bee_credential_definitions SET source_ref = 'bee.harness.launch:harness_setup' WHERE source_ref = 'bee.harness:harness_setup';
UPDATE bee_credential_definitions SET source_ref = 'bee.harness.binding:profiles_local' WHERE source_ref = 'bee.harness:profiles_local';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.manager.security:client_policy' WHERE source_ref = 'bee.hive.manager:client_policy';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.manager.app:directory' WHERE source_ref = 'bee.hive.manager:directory';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.manager.app:names' WHERE source_ref = 'bee.hive.manager:names';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.manager.security:viewer_policy' WHERE source_ref = 'bee.hive.manager:viewer_policy';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.telemetry.binding:catalog_list' WHERE source_ref = 'bee.hive.telemetry:catalog_list';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.telemetry.binding:cluster' WHERE source_ref = 'bee.hive.telemetry:cluster';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.telemetry.binding:holdings' WHERE source_ref = 'bee.hive.telemetry:holdings';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.telemetry.binding:presence' WHERE source_ref = 'bee.hive.telemetry:presence';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.telemetry.binding:sampling' WHERE source_ref = 'bee.hive.telemetry:sampling';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.telemetry.binding:stats' WHERE source_ref = 'bee.hive.telemetry:stats';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.exposure:catalog' WHERE source_ref = 'bee.hive:catalog';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.binding:client' WHERE source_ref = 'bee.hive:client';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.binding:invoke_check' WHERE source_ref = 'bee.hive:invoke_check';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.binding:output' WHERE source_ref = 'bee.hive:output';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.security:principals' WHERE source_ref = 'bee.hive:principals';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.workspace:workspace_query' WHERE source_ref = 'bee.hive:workspace_query';
UPDATE bee_credential_definitions SET source_ref = 'bee.host.processes.app:probe' WHERE source_ref = 'bee.host.processes:probe';
UPDATE bee_credential_definitions SET source_ref = 'bee.hub.modules.security:client_policy' WHERE source_ref = 'bee.hub.modules:client_policy';
UPDATE bee_credential_definitions SET source_ref = 'bee.hub.modules.security:hub_policy' WHERE source_ref = 'bee.hub.modules:hub_policy';
UPDATE bee_credential_definitions SET source_ref = 'bee.hub.modules.security:publication_policy' WHERE source_ref = 'bee.hub.modules:publication_policy';
UPDATE bee_credential_definitions SET source_ref = 'bee.hub.modules.security:self_update_policy' WHERE source_ref = 'bee.hub.modules:self_update_policy';
UPDATE bee_credential_definitions SET source_ref = 'bee.hub.package:binary_identity' WHERE source_ref = 'bee.hub:binary_identity';
UPDATE bee_credential_definitions SET source_ref = 'bee.hub.package:graph' WHERE source_ref = 'bee.hub:graph';
UPDATE bee_credential_definitions SET source_ref = 'bee.hub.activation:host_resources' WHERE source_ref = 'bee.hub:host_resources';
UPDATE bee_credential_definitions SET source_ref = 'bee.hub.package:inspection' WHERE source_ref = 'bee.hub:inspection';
UPDATE bee_credential_definitions SET source_ref = 'bee.hub.activation:installation' WHERE source_ref = 'bee.hub:installation';
UPDATE bee_credential_definitions SET source_ref = 'bee.hub.package:inventory' WHERE source_ref = 'bee.hub:inventory';
UPDATE bee_credential_definitions SET source_ref = 'bee.hub.package:inventory_reader' WHERE source_ref = 'bee.hub:inventory_reader';
UPDATE bee_credential_definitions SET source_ref = 'bee.hub.activation:migration_work' WHERE source_ref = 'bee.hub:migration_work';
UPDATE bee_credential_definitions SET source_ref = 'bee.hub.activation:migrations' WHERE source_ref = 'bee.hub:migrations';
UPDATE bee_credential_definitions SET source_ref = 'bee.hub.package:native_compat' WHERE source_ref = 'bee.hub:native_compat';
UPDATE bee_credential_definitions SET source_ref = 'bee.hub.package:plan' WHERE source_ref = 'bee.hub:plan';
UPDATE bee_credential_definitions SET source_ref = 'bee.hub.env:process_host_ref' WHERE source_ref = 'bee.hub:process_host_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.hub.env:publish_configuration_ref' WHERE source_ref = 'bee.hub:publish_configuration_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.hub.publication:publish_executor' WHERE source_ref = 'bee.hub:publish_executor';
UPDATE bee_credential_definitions SET source_ref = 'bee.hub.env:publish_executor_ref' WHERE source_ref = 'bee.hub:publish_executor_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.hub.publication:publishing' WHERE source_ref = 'bee.hub:publishing';
UPDATE bee_credential_definitions SET source_ref = 'bee.hub.package:requirements' WHERE source_ref = 'bee.hub:requirements';
UPDATE bee_credential_definitions SET source_ref = 'bee.hub.package:result' WHERE source_ref = 'bee.hub:result';
UPDATE bee_credential_definitions SET source_ref = 'bee.hub.package:semver' WHERE source_ref = 'bee.hub:semver';
UPDATE bee_credential_definitions SET source_ref = 'bee.node.env:database_ref' WHERE source_ref = 'bee.node:database_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.node.env:db' WHERE source_ref = 'bee.node:db';
UPDATE bee_credential_definitions SET source_ref = 'bee.node.env:db_path' WHERE source_ref = 'bee.node:db_path';
UPDATE bee_credential_definitions SET source_ref = 'bee.node.env:environment' WHERE source_ref = 'bee.node:environment';
UPDATE bee_credential_definitions SET source_ref = 'bee.node.env:resources' WHERE source_ref = 'bee.node:resources';
UPDATE bee_credential_definitions SET source_ref = 'bee.persist.persist:database' WHERE source_ref = 'bee.persist:database';
UPDATE bee_credential_definitions SET source_ref = 'bee.persist.persist:ledger' WHERE source_ref = 'bee.persist:ledger';
UPDATE bee_credential_definitions SET source_ref = 'bee.persist.persist:transaction' WHERE source_ref = 'bee.persist:transaction';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.docker.env:boot_environment' WHERE source_ref = 'bee.placement.docker:boot_environment';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.docker.profiles:coding' WHERE source_ref = 'bee.placement.docker:coding';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.docker.profiles:coding_recipe' WHERE source_ref = 'bee.placement.docker:coding_recipe';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.docker.env:environment' WHERE source_ref = 'bee.placement.docker:environment';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.docker.env:environment_configuration' WHERE source_ref = 'bee.placement.docker:environment_configuration';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.docker.binding:spec' WHERE source_ref = 'bee.placement.docker:spec';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.native.env:admitted_roots_ref' WHERE source_ref = 'bee.placement.native:admitted_roots_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.native.env:configuration' WHERE source_ref = 'bee.placement.native:configuration';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.native.env:database_ref' WHERE source_ref = 'bee.placement.native:database_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.native.env:db' WHERE source_ref = 'bee.placement.native:db';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.native.env:db_path' WHERE source_ref = 'bee.placement.native:db_path';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.native.env:environment' WHERE source_ref = 'bee.placement.native:environment';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.native.env:executor_ref' WHERE source_ref = 'bee.placement.native:executor_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.native.env:host_files_ref' WHERE source_ref = 'bee.placement.native:host_files_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.native.env:placement_admitted_roots' WHERE source_ref = 'bee.placement.native:placement_admitted_roots';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.native.env:placement_executor' WHERE source_ref = 'bee.placement.native:placement_executor';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.native.env:placement_host_files' WHERE source_ref = 'bee.placement.native:placement_host_files';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.native.env:placement_path' WHERE source_ref = 'bee.placement.native:placement_path';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.native.env:placement_resource_mode' WHERE source_ref = 'bee.placement.native:placement_resource_mode';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.native.env:placement_workdir_preparers' WHERE source_ref = 'bee.placement.native:placement_workdir_preparers';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.native.binding:process_backend' WHERE source_ref = 'bee.placement.native:process_backend';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.native.service:process_runner' WHERE source_ref = 'bee.placement.native:process_runner';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.native.env:resource_mode_ref' WHERE source_ref = 'bee.placement.native:resource_mode_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.native.env:resources' WHERE source_ref = 'bee.placement.native:resources';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.native.env:root' WHERE source_ref = 'bee.placement.native:root';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.native.env:root_path' WHERE source_ref = 'bee.placement.native:root_path';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.native.env:root_ref' WHERE source_ref = 'bee.placement.native:root_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.native.env:runner_host_ref' WHERE source_ref = 'bee.placement.native:runner_host_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.native.env:workdir_preparers_ref' WHERE source_ref = 'bee.placement.native:workdir_preparers_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.profiles:native' WHERE source_ref = 'bee.placement:native';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.profiles:paths' WHERE source_ref = 'bee.placement:paths';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.profiles:profiles' WHERE source_ref = 'bee.placement:profiles';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.binding:resolver' WHERE source_ref = 'bee.placement:resolver';
UPDATE bee_credential_definitions SET source_ref = 'bee.resources.env:database_ref' WHERE source_ref = 'bee.resources:database_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.resources.env:db' WHERE source_ref = 'bee.resources:db';
UPDATE bee_credential_definitions SET source_ref = 'bee.resources.env:db_path' WHERE source_ref = 'bee.resources:db_path';
UPDATE bee_credential_definitions SET source_ref = 'bee.resources.env:environment' WHERE source_ref = 'bee.resources:environment';
UPDATE bee_credential_definitions SET source_ref = 'bee.resources.binding:local' WHERE source_ref = 'bee.resources:local';
UPDATE bee_credential_definitions SET source_ref = 'bee.resources.env:node_identity_migration_source' WHERE source_ref = 'bee.resources:node_identity_migration_source';
UPDATE bee_credential_definitions SET source_ref = 'bee.resources.env:resource_roots' WHERE source_ref = 'bee.resources:resource_roots';
UPDATE bee_credential_definitions SET source_ref = 'bee.resources.env:resources' WHERE source_ref = 'bee.resources:resources';
UPDATE bee_credential_definitions SET source_ref = 'bee.resources.binding:resources_workspace_extension' WHERE source_ref = 'bee.resources:resources_workspace_extension';
UPDATE bee_credential_definitions SET source_ref = 'bee.resources.env:roots_ref' WHERE source_ref = 'bee.resources:roots_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.sessions.executor:driver_route' WHERE source_ref = 'bee.sessions:driver_route';
UPDATE bee_credential_definitions SET source_ref = 'bee.sessions.executor:executor_registry' WHERE source_ref = 'bee.sessions:executor_registry';
UPDATE bee_credential_definitions SET source_ref = 'bee.sessions.executor:executor_selection' WHERE source_ref = 'bee.sessions:executor_selection';
UPDATE bee_credential_definitions SET source_ref = 'bee.sessions.service:owner' WHERE source_ref = 'bee.sessions:owner';
UPDATE bee_credential_definitions SET source_ref = 'bee.sessions.binding:threads_journal' WHERE source_ref = 'bee.sessions:threads_journal';
UPDATE bee_credential_definitions SET source_ref = 'bee.sessions.env:threads_journal_ref' WHERE source_ref = 'bee.sessions:threads_journal_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.settings.app:build_info' WHERE source_ref = 'bee.settings:build_info';
UPDATE bee_credential_definitions SET source_ref = 'bee.sync.binding:admit' WHERE source_ref = 'bee.sync.hive:admit';
UPDATE bee_credential_definitions SET source_ref = 'bee.sync.values:bounds' WHERE source_ref = 'bee.sync:bounds';
UPDATE bee_credential_definitions SET source_ref = 'bee.sync.values:canonical' WHERE source_ref = 'bee.sync:canonical';
UPDATE bee_credential_definitions SET source_ref = 'bee.sync.env:database_ref' WHERE source_ref = 'bee.sync:database_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.sync.env:db' WHERE source_ref = 'bee.sync:db';
UPDATE bee_credential_definitions SET source_ref = 'bee.sync.env:db_path' WHERE source_ref = 'bee.sync:db_path';
UPDATE bee_credential_definitions SET source_ref = 'bee.sync.env:environment' WHERE source_ref = 'bee.sync:environment';
UPDATE bee_credential_definitions SET source_ref = 'bee.sync.env:exports_ref' WHERE source_ref = 'bee.sync:exports_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.sync.env:resources' WHERE source_ref = 'bee.sync:resources';
UPDATE bee_credential_definitions SET source_ref = 'bee.sync.values:version' WHERE source_ref = 'bee.sync:version';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:append' WHERE source_ref = 'bee.threads.approvals:append';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:cancel_intent' WHERE source_ref = 'bee.threads.carrier:cancel_intent';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:cancel_status' WHERE source_ref = 'bee.threads.carrier:cancel_status';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:checkpoint' WHERE source_ref = 'bee.threads.carrier:checkpoint';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:claim' WHERE source_ref = 'bee.threads.carrier:claim';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:commit' WHERE source_ref = 'bee.threads.carrier:commit';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:ack' WHERE source_ref = 'bee.threads.delivery:ack';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:ack_page' WHERE source_ref = 'bee.threads.delivery:ack_page';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:delivery_claim' WHERE source_ref = 'bee.threads.delivery:claim';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:close_subscription' WHERE source_ref = 'bee.threads.delivery:close_subscription';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:dispatch' WHERE source_ref = 'bee.threads.delivery:dispatch';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:expire' WHERE source_ref = 'bee.threads.delivery:expire';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:forget_subscription' WHERE source_ref = 'bee.threads.delivery:forget_subscription';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:page' WHERE source_ref = 'bee.threads.delivery:page';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:reconcile' WHERE source_ref = 'bee.threads.delivery:reconcile';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:release' WHERE source_ref = 'bee.threads.delivery:release';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:resume' WHERE source_ref = 'bee.threads.delivery:resume';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:subscribe' WHERE source_ref = 'bee.threads.delivery:subscribe';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:unsubscribe' WHERE source_ref = 'bee.threads.delivery:unsubscribe';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:wait' WHERE source_ref = 'bee.threads.delivery:wait';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.service:waiter' WHERE source_ref = 'bee.threads.delivery:waiter';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.service:waiter_service' WHERE source_ref = 'bee.threads.delivery:waiter_service';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:watch' WHERE source_ref = 'bee.threads.delivery:watch';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:recap_read' WHERE source_ref = 'bee.threads.projection:recap_read';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:recap_rebuild' WHERE source_ref = 'bee.threads.projection:recap_rebuild';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:recap_update' WHERE source_ref = 'bee.threads.projection:recap_update';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:status_read' WHERE source_ref = 'bee.threads.projection:status_read';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:status_rebuild' WHERE source_ref = 'bee.threads.projection:status_rebuild';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:status_update' WHERE source_ref = 'bee.threads.projection:status_update';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads:record_types' WHERE source_ref = 'bee.threads.records:types';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:admit_action' WHERE source_ref = 'bee.threads.service:admit_action';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:close' WHERE source_ref = 'bee.threads.service:close';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:create' WHERE source_ref = 'bee.threads.service:create';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:end_turn' WHERE source_ref = 'bee.threads.service:end_turn';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:feed_read' WHERE source_ref = 'bee.threads.service:feed_read';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:fence_app' WHERE source_ref = 'bee.threads.service:fence_app';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:get' WHERE source_ref = 'bee.threads.service:get';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:inbox_accept' WHERE source_ref = 'bee.threads.service:inbox_accept';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:inbox_ack' WHERE source_ref = 'bee.threads.service:inbox_ack';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:inbox_describe' WHERE source_ref = 'bee.threads.service:inbox_describe';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:inbox_list' WHERE source_ref = 'bee.threads.service:inbox_list';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:inbox_offer' WHERE source_ref = 'bee.threads.service:inbox_offer';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:inbox_outbox_claim' WHERE source_ref = 'bee.threads.service:inbox_outbox_claim';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:inbox_outbox_settle' WHERE source_ref = 'bee.threads.service:inbox_outbox_settle';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:inbox_reply' WHERE source_ref = 'bee.threads.service:inbox_reply';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:inbox_resolve' WHERE source_ref = 'bee.threads.service:inbox_resolve';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:inbox_send' WHERE source_ref = 'bee.threads.service:inbox_send';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:inbox_transport' WHERE source_ref = 'bee.threads.service:inbox_transport';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:join' WHERE source_ref = 'bee.threads.service:join';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:leave' WHERE source_ref = 'bee.threads.service:leave';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:list' WHERE source_ref = 'bee.threads.service:list';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:list_workspace' WHERE source_ref = 'bee.threads.service:list_workspace';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:notify' WHERE source_ref = 'bee.threads.service:notify';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:operation_describe' WHERE source_ref = 'bee.threads.service:operation_describe';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:operation_lookup' WHERE source_ref = 'bee.threads.service:operation_lookup';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:prepare_attempt' WHERE source_ref = 'bee.threads.service:prepare_attempt';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:read_after' WHERE source_ref = 'bee.threads.service:read_after';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:receipt' WHERE source_ref = 'bee.threads.service:receipt';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:record' WHERE source_ref = 'bee.threads.service:record';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:register_app_alias' WHERE source_ref = 'bee.threads.service:register_app_alias';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:request_turn' WHERE source_ref = 'bee.threads.service:request_turn';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:retire_app_alias' WHERE source_ref = 'bee.threads.service:retire_app_alias';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:send' WHERE source_ref = 'bee.threads.service:send';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:send_status' WHERE source_ref = 'bee.threads.service:send_status';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:session_attach' WHERE source_ref = 'bee.threads.service:session_attach';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:session_create' WHERE source_ref = 'bee.threads.service:session_create';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:session_describe' WHERE source_ref = 'bee.threads.service:session_describe';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:session_scan' WHERE source_ref = 'bee.threads.service:session_scan';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:session_transition' WHERE source_ref = 'bee.threads.service:session_transition';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:start_attempt' WHERE source_ref = 'bee.threads.service:start_attempt';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:turn_accept' WHERE source_ref = 'bee.threads.service:turn_accept';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:turn_observation' WHERE source_ref = 'bee.threads.service:turn_observation';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:turn_pull' WHERE source_ref = 'bee.threads.service:turn_pull';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:turn_recover' WHERE source_ref = 'bee.threads.service:turn_recover';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:turn_reserve' WHERE source_ref = 'bee.threads.service:turn_reserve';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads:types' WHERE source_ref = 'bee.threads.service:types';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:work_cancel' WHERE source_ref = 'bee.threads.service:work_cancel';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:work_describe' WHERE source_ref = 'bee.threads.service:work_describe';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:work_history' WHERE source_ref = 'bee.threads.service:work_history';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:work_scan' WHERE source_ref = 'bee.threads.service:work_scan';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:work_send' WHERE source_ref = 'bee.threads.service:work_send';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:work_settle' WHERE source_ref = 'bee.threads.service:work_settle';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:work_uncertain' WHERE source_ref = 'bee.threads.service:work_uncertain';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.timeline.security:client_policy' WHERE source_ref = 'bee.threads.timeline:client_policy';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:approvals_local' WHERE source_ref = 'bee.threads:approvals_local';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:authority_local' WHERE source_ref = 'bee.threads:authority_local';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:capabilities' WHERE source_ref = 'bee.threads:capabilities';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:capabilities_report' WHERE source_ref = 'bee.threads:capabilities_report';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:carrier_local' WHERE source_ref = 'bee.threads:carrier_local';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.env:database_path' WHERE source_ref = 'bee.threads:database_path';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.env:database_ref' WHERE source_ref = 'bee.threads:database_ref';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.env:db' WHERE source_ref = 'bee.threads:db';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:delivery_local' WHERE source_ref = 'bee.threads:delivery_local';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.env:environment' WHERE source_ref = 'bee.threads:environment';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:journal_local' WHERE source_ref = 'bee.threads:journal_local';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:lifecycle_local' WHERE source_ref = 'bee.threads:lifecycle_local';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.service:owner' WHERE source_ref = 'bee.threads:owner';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.service:owner_service' WHERE source_ref = 'bee.threads:owner_service';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.binding:projection_local' WHERE source_ref = 'bee.threads:projection_local';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.env:resources' WHERE source_ref = 'bee.threads:resources';
UPDATE bee_credential_definitions SET source_ref = 'bee.workspace.manager.security:client_policy' WHERE source_ref = 'bee.workspace.manager:client_policy';
UPDATE bee_credential_definitions SET source_ref = 'bee.security.approvals:approver_policies' WHERE source_ref = 'bee:approver_policies';
UPDATE bee_credential_definitions SET source_ref = 'bee.security.capability:capability_catalog' WHERE source_ref = 'bee:capability_catalog';
UPDATE bee_credential_definitions SET source_ref = 'bee.protocol:clock' WHERE source_ref = 'bee:clock';
UPDATE bee_credential_definitions SET source_ref = 'bee.env:docs_corpus' WHERE source_ref = 'bee:docs_corpus';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.api:gateway_endpoint' WHERE source_ref = 'bee:gateway_endpoint';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.service:gateway_installation_service' WHERE source_ref = 'bee:gateway_installation_service';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.api:gateway_listener' WHERE source_ref = 'bee:gateway_listener';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.api:gateway_mcp' WHERE source_ref = 'bee:gateway_mcp';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.service:gateway_publication_service' WHERE source_ref = 'bee:gateway_publication_service';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.api:gateway_ready' WHERE source_ref = 'bee:gateway_ready';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.api:gateway_router' WHERE source_ref = 'bee:gateway_router';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.binding:gateway_workspace_extension' WHERE source_ref = 'bee:gateway_workspace_extension';
UPDATE bee_credential_definitions SET source_ref = 'bee.gov.service:gov_recovery_service' WHERE source_ref = 'bee:gov_recovery_service';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.supervisor:hive_operation_adapters' WHERE source_ref = 'bee:hive_operation_adapters';
UPDATE bee_credential_definitions SET source_ref = 'bee.hub.publication:hub_publication' WHERE source_ref = 'bee:hub_publication';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.env:module_installation' WHERE source_ref = 'bee:module_installation';
UPDATE bee_credential_definitions SET source_ref = 'bee.gateway.env:module_publication' WHERE source_ref = 'bee:module_publication';
UPDATE bee_credential_definitions SET source_ref = 'bee.security.gov:protected_kernel' WHERE source_ref = 'bee:protected_kernel';
UPDATE bee_credential_definitions SET source_ref = 'bee.sync.service:sync_distribution_service' WHERE source_ref = 'bee:sync_distribution_service';
UPDATE bee_credential_definitions SET source_ref = 'bee.sync.env:sync_exports' WHERE source_ref = 'bee:sync_exports';
UPDATE bee_credential_definitions SET source_ref = 'bee.threads.service:thread_outbox_pump_service' WHERE source_ref = 'bee:thread_outbox_pump_service';
UPDATE bee_credential_definitions SET source_ref = 'bee.placement.native.env:workdir_preparers' WHERE source_ref = 'bee:workdir_preparers';
UPDATE bee_credential_definitions SET source_ref = 'bee.launch.service:workspace_hosts' WHERE source_ref = 'bee:workspace_hosts';
UPDATE bee_credential_projections SET materializer = 'bee.approvals.inbox.app:client' WHERE materializer = 'bee.approvals.inbox:client';
UPDATE bee_credential_projections SET materializer = 'bee.approvals.inbox.security:client_policy' WHERE materializer = 'bee.approvals.inbox:client_policy';
UPDATE bee_credential_projections SET materializer = 'bee.approvals.inbox.app:source_config' WHERE materializer = 'bee.approvals.inbox:source_config';
UPDATE bee_credential_projections SET materializer = 'bee.approvals.inbox.app:sources' WHERE materializer = 'bee.approvals.inbox:sources';
UPDATE bee_credential_projections SET materializer = 'bee.approvals.inbox.app:workspaces' WHERE materializer = 'bee.approvals.inbox:workspaces';
UPDATE bee_credential_projections SET materializer = 'bee.approvals.env:database_ref' WHERE materializer = 'bee.approvals:database_ref';
UPDATE bee_credential_projections SET materializer = 'bee.approvals.env:db' WHERE materializer = 'bee.approvals:db';
UPDATE bee_credential_projections SET materializer = 'bee.approvals.env:db_path' WHERE materializer = 'bee.approvals:db_path';
UPDATE bee_credential_projections SET materializer = 'bee.approvals.env:environment' WHERE materializer = 'bee.approvals:environment';
UPDATE bee_credential_projections SET materializer = 'bee.approvals.migrations:identity_migration' WHERE materializer = 'bee.approvals:identity_migration';
UPDATE bee_credential_projections SET materializer = 'bee.approvals.binding:local' WHERE materializer = 'bee.approvals:local';
UPDATE bee_credential_projections SET materializer = 'bee.approvals.env:node_identity_migration_source' WHERE materializer = 'bee.approvals:node_identity_migration_source';
UPDATE bee_credential_projections SET materializer = 'bee.approvals.env:policies_ref' WHERE materializer = 'bee.approvals:policies_ref';
UPDATE bee_credential_projections SET materializer = 'bee.approvals.env:resources' WHERE materializer = 'bee.approvals:resources';
UPDATE bee_credential_projections SET materializer = 'bee.approvals.service:runtime_lease' WHERE materializer = 'bee.approvals:runtime_lease';
UPDATE bee_credential_projections SET materializer = 'bee.approvals.service:service' WHERE materializer = 'bee.approvals:service';
UPDATE bee_credential_projections SET materializer = 'bee.console.app:command' WHERE materializer = 'bee.console:command';
UPDATE bee_credential_projections SET materializer = 'bee.console.security:command_policy' WHERE materializer = 'bee.console:command_policy';
UPDATE bee_credential_projections SET materializer = 'bee.console.env:environment' WHERE materializer = 'bee.console:environment';
UPDATE bee_credential_projections SET materializer = 'bee.console.env:executor' WHERE materializer = 'bee.console:executor';
UPDATE bee_credential_projections SET materializer = 'bee.console.security:executor_policy' WHERE materializer = 'bee.console:executor_policy';
UPDATE bee_credential_projections SET materializer = 'bee.console.env:home' WHERE materializer = 'bee.console:home';
UPDATE bee_credential_projections SET materializer = 'bee.console.env:lang' WHERE materializer = 'bee.console:lang';
UPDATE bee_credential_projections SET materializer = 'bee.console.env:path' WHERE materializer = 'bee.console:path';
UPDATE bee_credential_projections SET materializer = 'bee.console.env:user' WHERE materializer = 'bee.console:user';
UPDATE bee_credential_projections SET materializer = 'bee.credentials.env:credential_sources' WHERE materializer = 'bee.credentials:credential_sources';
UPDATE bee_credential_projections SET materializer = 'bee.credentials.env:database_ref' WHERE materializer = 'bee.credentials:database_ref';
UPDATE bee_credential_projections SET materializer = 'bee.credentials.env:db' WHERE materializer = 'bee.credentials:db';
UPDATE bee_credential_projections SET materializer = 'bee.credentials.env:db_path' WHERE materializer = 'bee.credentials:db_path';
UPDATE bee_credential_projections SET materializer = 'bee.credentials.env:environment' WHERE materializer = 'bee.credentials:environment';
UPDATE bee_credential_projections SET materializer = 'bee.credentials.binding:local' WHERE materializer = 'bee.credentials:local';
UPDATE bee_credential_projections SET materializer = 'bee.credentials.env:materializer_ref' WHERE materializer = 'bee.credentials:materializer_ref';
UPDATE bee_credential_projections SET materializer = 'bee.credentials.env:node_identity_migration_source' WHERE materializer = 'bee.credentials:node_identity_migration_source';
UPDATE bee_credential_projections SET materializer = 'bee.credentials.env:sources' WHERE materializer = 'bee.credentials:sources';
UPDATE bee_credential_projections SET materializer = 'bee.credentials.env:sources_ref' WHERE materializer = 'bee.credentials:sources_ref';
UPDATE bee_credential_projections SET materializer = 'bee.docs.binding:corpus' WHERE materializer = 'bee.docs:corpus';
UPDATE bee_credential_projections SET materializer = 'bee.docs.env:corpus_ref' WHERE materializer = 'bee.docs:corpus_ref';
UPDATE bee_credential_projections SET materializer = 'bee.docs.env:resources' WHERE materializer = 'bee.docs:resources';
UPDATE bee_credential_projections SET materializer = 'bee.driver.agy.binding:binding' WHERE materializer = 'bee.driver.agy:binding';
UPDATE bee_credential_projections SET materializer = 'bee.driver.agy.descriptor:command' WHERE materializer = 'bee.driver.agy:command';
UPDATE bee_credential_projections SET materializer = 'bee.driver.agy.binding:configuration' WHERE materializer = 'bee.driver.agy:configuration';
UPDATE bee_credential_projections SET materializer = 'bee.driver.agy.credentials:credential_format' WHERE materializer = 'bee.driver.agy:credential_format';
UPDATE bee_credential_projections SET materializer = 'bee.driver.agy.profiles:default_window' WHERE materializer = 'bee.driver.agy:default_window';
UPDATE bee_credential_projections SET materializer = 'bee.driver.agy.env:executable' WHERE materializer = 'bee.driver.agy:executable';
UPDATE bee_credential_projections SET materializer = 'bee.driver.agy.binding:launch' WHERE materializer = 'bee.driver.agy:launch';
UPDATE bee_credential_projections SET materializer = 'bee.driver.agy.security:launch_policy_agy_batch' WHERE materializer = 'bee.driver.agy:launch_policy_agy_batch';
UPDATE bee_credential_projections SET materializer = 'bee.driver.agy.security:launch_policy_agy_window' WHERE materializer = 'bee.driver.agy:launch_policy_agy_window';
UPDATE bee_credential_projections SET materializer = 'bee.driver.agy.descriptor:locate' WHERE materializer = 'bee.driver.agy:locate';
UPDATE bee_credential_projections SET materializer = 'bee.driver.agy.profiles:profiles' WHERE materializer = 'bee.driver.agy:profiles';
UPDATE bee_credential_projections SET materializer = 'bee.driver.agy.binding:protocol' WHERE materializer = 'bee.driver.agy:protocol';
UPDATE bee_credential_projections SET materializer = 'bee.driver.agy.profiles:research_batch' WHERE materializer = 'bee.driver.agy:research_batch';
UPDATE bee_credential_projections SET materializer = 'bee.driver.claude.env:api_key' WHERE materializer = 'bee.driver.claude:api_key';
UPDATE bee_credential_projections SET materializer = 'bee.driver.claude.binding:binding' WHERE materializer = 'bee.driver.claude:binding';
UPDATE bee_credential_projections SET materializer = 'bee.driver.claude.descriptor:command' WHERE materializer = 'bee.driver.claude:command';
UPDATE bee_credential_projections SET materializer = 'bee.driver.claude.env:config_home' WHERE materializer = 'bee.driver.claude:config_home';
UPDATE bee_credential_projections SET materializer = 'bee.driver.claude.credentials:credential_format' WHERE materializer = 'bee.driver.claude:credential_format';
UPDATE bee_credential_projections SET materializer = 'bee.driver.claude.profiles:default_window' WHERE materializer = 'bee.driver.claude:default_window';
UPDATE bee_credential_projections SET materializer = 'bee.driver.claude.env:executable' WHERE materializer = 'bee.driver.claude:executable';
UPDATE bee_credential_projections SET materializer = 'bee.driver.claude.binding:launch' WHERE materializer = 'bee.driver.claude:launch';
UPDATE bee_credential_projections SET materializer = 'bee.driver.claude.security:launch_policy_claude_batch' WHERE materializer = 'bee.driver.claude:launch_policy_claude_batch';
UPDATE bee_credential_projections SET materializer = 'bee.driver.claude.security:launch_policy_claude_window' WHERE materializer = 'bee.driver.claude:launch_policy_claude_window';
UPDATE bee_credential_projections SET materializer = 'bee.driver.claude.descriptor:locate' WHERE materializer = 'bee.driver.claude:locate';
UPDATE bee_credential_projections SET materializer = 'bee.driver.claude.permission:permission_adapter' WHERE materializer = 'bee.driver.claude:permission_adapter';
UPDATE bee_credential_projections SET materializer = 'bee.driver.claude.profiles:profiles' WHERE materializer = 'bee.driver.claude:profiles';
UPDATE bee_credential_projections SET materializer = 'bee.driver.claude.binding:protocol' WHERE materializer = 'bee.driver.claude:protocol';
UPDATE bee_credential_projections SET materializer = 'bee.driver.claude.profiles:research_batch' WHERE materializer = 'bee.driver.claude:research_batch';
UPDATE bee_credential_projections SET materializer = 'bee.driver.codex.binding:binding' WHERE materializer = 'bee.driver.codex:binding';
UPDATE bee_credential_projections SET materializer = 'bee.driver.codex.descriptor:command' WHERE materializer = 'bee.driver.codex:command';
UPDATE bee_credential_projections SET materializer = 'bee.driver.codex.env:config_home' WHERE materializer = 'bee.driver.codex:config_home';
UPDATE bee_credential_projections SET materializer = 'bee.driver.codex.binding:configuration' WHERE materializer = 'bee.driver.codex:configuration';
UPDATE bee_credential_projections SET materializer = 'bee.driver.codex.credentials:credential_format' WHERE materializer = 'bee.driver.codex:credential_format';
UPDATE bee_credential_projections SET materializer = 'bee.driver.codex.descriptor:default_provider' WHERE materializer = 'bee.driver.codex:default_provider';
UPDATE bee_credential_projections SET materializer = 'bee.driver.codex.profiles:default_window' WHERE materializer = 'bee.driver.codex:default_window';
UPDATE bee_credential_projections SET materializer = 'bee.driver.codex.env:executable' WHERE materializer = 'bee.driver.codex:executable';
UPDATE bee_credential_projections SET materializer = 'bee.driver.codex.binding:launch' WHERE materializer = 'bee.driver.codex:launch';
UPDATE bee_credential_projections SET materializer = 'bee.driver.codex.security:launch_policy_codex_batch' WHERE materializer = 'bee.driver.codex:launch_policy_codex_batch';
UPDATE bee_credential_projections SET materializer = 'bee.driver.codex.security:launch_policy_codex_named_batch' WHERE materializer = 'bee.driver.codex:launch_policy_codex_named_batch';
UPDATE bee_credential_projections SET materializer = 'bee.driver.codex.security:launch_policy_codex_window' WHERE materializer = 'bee.driver.codex:launch_policy_codex_window';
UPDATE bee_credential_projections SET materializer = 'bee.driver.codex.descriptor:locate' WHERE materializer = 'bee.driver.codex:locate';
UPDATE bee_credential_projections SET materializer = 'bee.driver.codex.profiles:named_batch' WHERE materializer = 'bee.driver.codex:named_batch';
UPDATE bee_credential_projections SET materializer = 'bee.driver.codex.profiles:profiles' WHERE materializer = 'bee.driver.codex:profiles';
UPDATE bee_credential_projections SET materializer = 'bee.driver.codex.binding:protocol' WHERE materializer = 'bee.driver.codex:protocol';
UPDATE bee_credential_projections SET materializer = 'bee.driver.codex.profiles:research_batch' WHERE materializer = 'bee.driver.codex:research_batch';
UPDATE bee_credential_projections SET materializer = 'bee.driver.grok.binding:binding' WHERE materializer = 'bee.driver.grok:binding';
UPDATE bee_credential_projections SET materializer = 'bee.driver.grok.descriptor:command' WHERE materializer = 'bee.driver.grok:command';
UPDATE bee_credential_projections SET materializer = 'bee.driver.grok.binding:configuration' WHERE materializer = 'bee.driver.grok:configuration';
UPDATE bee_credential_projections SET materializer = 'bee.driver.grok.credentials:credential_format' WHERE materializer = 'bee.driver.grok:credential_format';
UPDATE bee_credential_projections SET materializer = 'bee.driver.grok.profiles:default_window' WHERE materializer = 'bee.driver.grok:default_window';
UPDATE bee_credential_projections SET materializer = 'bee.driver.grok.env:executable' WHERE materializer = 'bee.driver.grok:executable';
UPDATE bee_credential_projections SET materializer = 'bee.driver.grok.binding:launch' WHERE materializer = 'bee.driver.grok:launch';
UPDATE bee_credential_projections SET materializer = 'bee.driver.grok.security:launch_policy_grok_batch' WHERE materializer = 'bee.driver.grok:launch_policy_grok_batch';
UPDATE bee_credential_projections SET materializer = 'bee.driver.grok.security:launch_policy_grok_window' WHERE materializer = 'bee.driver.grok:launch_policy_grok_window';
UPDATE bee_credential_projections SET materializer = 'bee.driver.grok.descriptor:locate' WHERE materializer = 'bee.driver.grok:locate';
UPDATE bee_credential_projections SET materializer = 'bee.driver.grok.profiles:profiles' WHERE materializer = 'bee.driver.grok:profiles';
UPDATE bee_credential_projections SET materializer = 'bee.driver.grok.binding:protocol' WHERE materializer = 'bee.driver.grok:protocol';
UPDATE bee_credential_projections SET materializer = 'bee.driver.grok.profiles:research_batch' WHERE materializer = 'bee.driver.grok:research_batch';
UPDATE bee_credential_projections SET materializer = 'bee.driver.muse.binding:binding' WHERE materializer = 'bee.driver.muse:binding';
UPDATE bee_credential_projections SET materializer = 'bee.driver.muse.descriptor:command' WHERE materializer = 'bee.driver.muse:command';
UPDATE bee_credential_projections SET materializer = 'bee.driver.muse.binding:configuration' WHERE materializer = 'bee.driver.muse:configuration';
UPDATE bee_credential_projections SET materializer = 'bee.driver.muse.credentials:credential_format' WHERE materializer = 'bee.driver.muse:credential_format';
UPDATE bee_credential_projections SET materializer = 'bee.driver.muse.profiles:default_window' WHERE materializer = 'bee.driver.muse:default_window';
UPDATE bee_credential_projections SET materializer = 'bee.driver.muse.env:executable' WHERE materializer = 'bee.driver.muse:executable';
UPDATE bee_credential_projections SET materializer = 'bee.driver.muse.binding:launch' WHERE materializer = 'bee.driver.muse:launch';
UPDATE bee_credential_projections SET materializer = 'bee.driver.muse.security:launch_policy_muse_batch' WHERE materializer = 'bee.driver.muse:launch_policy_muse_batch';
UPDATE bee_credential_projections SET materializer = 'bee.driver.muse.security:launch_policy_muse_window' WHERE materializer = 'bee.driver.muse:launch_policy_muse_window';
UPDATE bee_credential_projections SET materializer = 'bee.driver.muse.descriptor:locate' WHERE materializer = 'bee.driver.muse:locate';
UPDATE bee_credential_projections SET materializer = 'bee.driver.muse.profiles:profiles' WHERE materializer = 'bee.driver.muse:profiles';
UPDATE bee_credential_projections SET materializer = 'bee.driver.muse.binding:protocol' WHERE materializer = 'bee.driver.muse:protocol';
UPDATE bee_credential_projections SET materializer = 'bee.driver.muse.profiles:research_batch' WHERE materializer = 'bee.driver.muse:research_batch';
UPDATE bee_credential_projections SET materializer = 'bee.driver.opencode.binding:binding' WHERE materializer = 'bee.driver.opencode:binding';
UPDATE bee_credential_projections SET materializer = 'bee.driver.opencode.descriptor:command' WHERE materializer = 'bee.driver.opencode:command';
UPDATE bee_credential_projections SET materializer = 'bee.driver.opencode.binding:configuration' WHERE materializer = 'bee.driver.opencode:configuration';
UPDATE bee_credential_projections SET materializer = 'bee.driver.opencode.credentials:credential_format' WHERE materializer = 'bee.driver.opencode:credential_format';
UPDATE bee_credential_projections SET materializer = 'bee.driver.opencode.profiles:default_window' WHERE materializer = 'bee.driver.opencode:default_window';
UPDATE bee_credential_projections SET materializer = 'bee.driver.opencode.env:executable' WHERE materializer = 'bee.driver.opencode:executable';
UPDATE bee_credential_projections SET materializer = 'bee.driver.opencode.binding:launch' WHERE materializer = 'bee.driver.opencode:launch';
UPDATE bee_credential_projections SET materializer = 'bee.driver.opencode.security:launch_policy_opencode_batch' WHERE materializer = 'bee.driver.opencode:launch_policy_opencode_batch';
UPDATE bee_credential_projections SET materializer = 'bee.driver.opencode.security:launch_policy_opencode_window' WHERE materializer = 'bee.driver.opencode:launch_policy_opencode_window';
UPDATE bee_credential_projections SET materializer = 'bee.driver.opencode.descriptor:locate' WHERE materializer = 'bee.driver.opencode:locate';
UPDATE bee_credential_projections SET materializer = 'bee.driver.opencode.profiles:profiles' WHERE materializer = 'bee.driver.opencode:profiles';
UPDATE bee_credential_projections SET materializer = 'bee.driver.opencode.binding:protocol' WHERE materializer = 'bee.driver.opencode:protocol';
UPDATE bee_credential_projections SET materializer = 'bee.driver.opencode.profiles:research_batch' WHERE materializer = 'bee.driver.opencode:research_batch';
UPDATE bee_credential_projections SET materializer = 'bee.driver.wippy.binding:binding' WHERE materializer = 'bee.driver.wippy:binding';
UPDATE bee_credential_projections SET materializer = 'bee.driver.wippy.binding:client' WHERE materializer = 'bee.driver.wippy:client';
UPDATE bee_credential_projections SET materializer = 'bee.driver.wippy.env:host_config' WHERE materializer = 'bee.driver.wippy:host_config';
UPDATE bee_credential_projections SET materializer = 'bee.driver.wippy.profiles:profiles' WHERE materializer = 'bee.driver.wippy:profiles';
UPDATE bee_credential_projections SET materializer = 'bee.driver.wippy.binding:run' WHERE materializer = 'bee.driver.wippy:run';
UPDATE bee_credential_projections SET materializer = 'bee.driver.wippy.service:runner' WHERE materializer = 'bee.driver.wippy:runner';
UPDATE bee_credential_projections SET materializer = 'bee.driver.codec:codec_registry' WHERE materializer = 'bee.driver:codec_registry';
UPDATE bee_credential_projections SET materializer = 'bee.driver.configuration:configuration' WHERE materializer = 'bee.driver:configuration';
UPDATE bee_credential_projections SET materializer = 'bee.driver.descriptor:descriptor' WHERE materializer = 'bee.driver:descriptor';
UPDATE bee_credential_projections SET materializer = 'bee.driver.profiles:instructions' WHERE materializer = 'bee.driver:instructions';
UPDATE bee_credential_projections SET materializer = 'bee.driver.locate:locate' WHERE materializer = 'bee.driver:locate';
UPDATE bee_credential_projections SET materializer = 'bee.driver.locate:login_evidence' WHERE materializer = 'bee.driver:login_evidence';
UPDATE bee_credential_projections SET materializer = 'bee.driver.configuration:option_render' WHERE materializer = 'bee.driver:option_render';
UPDATE bee_credential_projections SET materializer = 'bee.driver.permission:permission_request_hook' WHERE materializer = 'bee.driver:permission_request_hook';
UPDATE bee_credential_projections SET materializer = 'bee.driver.profiles:preferences' WHERE materializer = 'bee.driver:preferences';
UPDATE bee_credential_projections SET materializer = 'bee.driver.locate:probe_capture' WHERE materializer = 'bee.driver:probe_capture';
UPDATE bee_credential_projections SET materializer = 'bee.driver.profiles:profile' WHERE materializer = 'bee.driver:profile';
UPDATE bee_credential_projections SET materializer = 'bee.driver.profiles:profile_access' WHERE materializer = 'bee.driver:profile_access';
UPDATE bee_credential_projections SET materializer = 'bee.driver.binding:resolver' WHERE materializer = 'bee.driver:resolver';
UPDATE bee_credential_projections SET materializer = 'bee.driver.descriptor:schema_values' WHERE materializer = 'bee.driver:schema_values';
UPDATE bee_credential_projections SET materializer = 'bee.driver.binding:universal' WHERE materializer = 'bee.driver:universal';
UPDATE bee_credential_projections SET materializer = 'bee.files.app:gitignore' WHERE materializer = 'bee.files:gitignore';
UPDATE bee_credential_projections SET materializer = 'bee.files.app:source' WHERE materializer = 'bee.files:source';
UPDATE bee_credential_projections SET materializer = 'bee.files.app:syntax' WHERE materializer = 'bee.files:syntax';
UPDATE bee_credential_projections SET materializer = 'bee.files.app:tree' WHERE materializer = 'bee.files:tree';
UPDATE bee_credential_projections SET materializer = 'bee.files.env:workspace_root_ref' WHERE materializer = 'bee.files:workspace_root_ref';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.binding:address' WHERE materializer = 'bee.gateway:address';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.api:address_value' WHERE materializer = 'bee.gateway:address_value';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.env:approval_consume_policy_ref' WHERE materializer = 'bee.gateway:approval_consume_policy_ref';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.env:approval_request_policy_ref' WHERE materializer = 'bee.gateway:approval_request_policy_ref';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.catalog:catalog' WHERE materializer = 'bee.gateway:catalog';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.env:configuration' WHERE materializer = 'bee.gateway:configuration';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.catalog:context' WHERE materializer = 'bee.gateway:context';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.env:database_ref' WHERE materializer = 'bee.gateway:database_ref';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.env:db' WHERE materializer = 'bee.gateway:db';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.env:db_path' WHERE materializer = 'bee.gateway:db_path';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.env:endpoint_ref' WHERE materializer = 'bee.gateway:endpoint_ref';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.env:environment' WHERE materializer = 'bee.gateway:environment';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.env:hook_executable' WHERE materializer = 'bee.gateway:hook_executable';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.hooks:hooks' WHERE materializer = 'bee.gateway:hooks';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.env:install_configuration_ref' WHERE materializer = 'bee.gateway:install_configuration_ref';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.catalog:json_schema' WHERE materializer = 'bee.gateway:json_schema';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.env:listener_ref' WHERE materializer = 'bee.gateway:listener_ref';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.api:mcp' WHERE materializer = 'bee.gateway:mcp';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.catalog:profile_scope' WHERE materializer = 'bee.gateway:profile_scope';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.env:publish_configuration_ref' WHERE materializer = 'bee.gateway:publish_configuration_ref';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.catalog:session_bundle' WHERE materializer = 'bee.gateway:session_bundle';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.catalog:session_tools' WHERE materializer = 'bee.gateway:session_tools';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.catalog:sessions' WHERE materializer = 'bee.gateway:sessions';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.catalog:surface' WHERE materializer = 'bee.gateway:surface';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.env:tool_application_open_policy_ref' WHERE materializer = 'bee.gateway:tool_application_open_policy_ref';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.env:tool_components_policy_ref' WHERE materializer = 'bee.gateway:tool_components_policy_ref';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.env:tool_delivery_policy_ref' WHERE materializer = 'bee.gateway:tool_delivery_policy_ref';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.env:tool_docs_policy_ref' WHERE materializer = 'bee.gateway:tool_docs_policy_ref';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.env:tool_hub_publish_policy_ref' WHERE materializer = 'bee.gateway:tool_hub_publish_policy_ref';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.env:tool_install_policy_ref' WHERE materializer = 'bee.gateway:tool_install_policy_ref';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.env:tool_message_policy_ref' WHERE materializer = 'bee.gateway:tool_message_policy_ref';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.env:tool_overlay_policy_ref' WHERE materializer = 'bee.gateway:tool_overlay_policy_ref';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.env:tool_publish_policy_ref' WHERE materializer = 'bee.gateway:tool_publish_policy_ref';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.env:tool_read_policy_ref' WHERE materializer = 'bee.gateway:tool_read_policy_ref';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.env:tool_session_policy_ref' WHERE materializer = 'bee.gateway:tool_session_policy_ref';
UPDATE bee_credential_projections SET materializer = 'bee.git.worktree.binding:binding' WHERE materializer = 'bee.git.worktree:binding';
UPDATE bee_credential_projections SET materializer = 'bee.git.worktree.binding:cleanup' WHERE materializer = 'bee.git.worktree:cleanup';
UPDATE bee_credential_projections SET materializer = 'bee.git.worktree.env:executor_ref' WHERE materializer = 'bee.git.worktree:executor_ref';
UPDATE bee_credential_projections SET materializer = 'bee.git.worktree.env:git_executor' WHERE materializer = 'bee.git.worktree:git_executor';
UPDATE bee_credential_projections SET materializer = 'bee.git.worktree.binding:git_roots' WHERE materializer = 'bee.git.worktree:git_roots';
UPDATE bee_credential_projections SET materializer = 'bee.git.worktree.env:host_files' WHERE materializer = 'bee.git.worktree:host_files';
UPDATE bee_credential_projections SET materializer = 'bee.git.worktree.env:host_files_ref' WHERE materializer = 'bee.git.worktree:host_files_ref';
UPDATE bee_credential_projections SET materializer = 'bee.git.worktree.binding:plan' WHERE materializer = 'bee.git.worktree:plan';
UPDATE bee_credential_projections SET materializer = 'bee.git.worktree.binding:setup' WHERE materializer = 'bee.git.worktree:setup';
UPDATE bee_credential_projections SET materializer = 'bee.git.worktree.binding:worktree' WHERE materializer = 'bee.git.worktree:worktree';
UPDATE bee_credential_projections SET materializer = 'bee.git.worktree.security:worktree_policy' WHERE materializer = 'bee.git.worktree:worktree_policy';
UPDATE bee_credential_projections SET materializer = 'bee.git.worktree.binding:binding' WHERE materializer = 'bee.git_worktree:binding';
UPDATE bee_credential_projections SET materializer = 'bee.git.worktree.binding:cleanup' WHERE materializer = 'bee.git_worktree:cleanup';
UPDATE bee_credential_projections SET materializer = 'bee.git.worktree:definition' WHERE materializer = 'bee.git_worktree:definition';
UPDATE bee_credential_projections SET materializer = 'bee.git.worktree:dependency_driver' WHERE materializer = 'bee.git_worktree:dependency_driver';
UPDATE bee_credential_projections SET materializer = 'bee.git.worktree:dependency_placement' WHERE materializer = 'bee.git_worktree:dependency_placement';
UPDATE bee_credential_projections SET materializer = 'bee.git.worktree:dependency_threads' WHERE materializer = 'bee.git_worktree:dependency_threads';
UPDATE bee_credential_projections SET materializer = 'bee.git.worktree.env:executor_ref' WHERE materializer = 'bee.git_worktree:executor_ref';
UPDATE bee_credential_projections SET materializer = 'bee.git.worktree.env:git_executor' WHERE materializer = 'bee.git_worktree:git_executor';
UPDATE bee_credential_projections SET materializer = 'bee.git.worktree.binding:git_roots' WHERE materializer = 'bee.git_worktree:git_roots';
UPDATE bee_credential_projections SET materializer = 'bee.git.worktree.env:host_files' WHERE materializer = 'bee.git_worktree:host_files';
UPDATE bee_credential_projections SET materializer = 'bee.git.worktree.env:host_files_ref' WHERE materializer = 'bee.git_worktree:host_files_ref';
UPDATE bee_credential_projections SET materializer = 'bee.git.worktree.binding:plan' WHERE materializer = 'bee.git_worktree:plan';
UPDATE bee_credential_projections SET materializer = 'bee.git.worktree:protected_namespace' WHERE materializer = 'bee.git_worktree:protected_namespace';
UPDATE bee_credential_projections SET materializer = 'bee.git.worktree.binding:setup' WHERE materializer = 'bee.git_worktree:setup';
UPDATE bee_credential_projections SET materializer = 'bee.git.worktree:target_executor' WHERE materializer = 'bee.git_worktree:target_executor';
UPDATE bee_credential_projections SET materializer = 'bee.git.worktree:target_host_files' WHERE materializer = 'bee.git_worktree:target_host_files';
UPDATE bee_credential_projections SET materializer = 'bee.git.worktree.binding:worktree' WHERE materializer = 'bee.git_worktree:worktree';
UPDATE bee_credential_projections SET materializer = 'bee.git.worktree.security:worktree_policy' WHERE materializer = 'bee.git_worktree:worktree_policy';
UPDATE bee_credential_projections SET materializer = 'bee.gov.overlays.security:client_policy' WHERE materializer = 'bee.gov.overlays:client_policy';
UPDATE bee_credential_projections SET materializer = 'bee.gov.activation:activation_measure' WHERE materializer = 'bee.gov:activation_measure';
UPDATE bee_credential_projections SET materializer = 'bee.gov.activation:activation_profile_decoder' WHERE materializer = 'bee.gov:activation_profile_decoder';
UPDATE bee_credential_projections SET materializer = 'bee.gov.env:activation_profiles_ref' WHERE materializer = 'bee.gov:activation_profiles_ref';
UPDATE bee_credential_projections SET materializer = 'bee.gov.activation:application_admissions' WHERE materializer = 'bee.gov:application_admissions';
UPDATE bee_credential_projections SET materializer = 'bee.gov.env:approval_consume_policy_ref' WHERE materializer = 'bee.gov:approval_consume_policy_ref';
UPDATE bee_credential_projections SET materializer = 'bee.gov.env:approval_request_policy_ref' WHERE materializer = 'bee.gov:approval_request_policy_ref';
UPDATE bee_credential_projections SET materializer = 'bee.gov.delivery:artifact' WHERE materializer = 'bee.gov:artifact';
UPDATE bee_credential_projections SET materializer = 'bee.gov.delivery:candidate' WHERE materializer = 'bee.gov:candidate';
UPDATE bee_credential_projections SET materializer = 'bee.gov.capability:capability_files' WHERE materializer = 'bee.gov:capability_files';
UPDATE bee_credential_projections SET materializer = 'bee.gov.capability:capability_gateway' WHERE materializer = 'bee.gov:capability_gateway';
UPDATE bee_credential_projections SET materializer = 'bee.gov.capability:capability_grants' WHERE materializer = 'bee.gov:capability_grants';
UPDATE bee_credential_projections SET materializer = 'bee.gov.capability:capability_request' WHERE materializer = 'bee.gov:capability_request';
UPDATE bee_credential_projections SET materializer = 'bee.gov.env:database_ref' WHERE materializer = 'bee.gov:database_ref';
UPDATE bee_credential_projections SET materializer = 'bee.gov.env:db' WHERE materializer = 'bee.gov:db';
UPDATE bee_credential_projections SET materializer = 'bee.gov.env:db_path' WHERE materializer = 'bee.gov:db_path';
UPDATE bee_credential_projections SET materializer = 'bee.gov.delivery:delivery' WHERE materializer = 'bee.gov:delivery';
UPDATE bee_credential_projections SET materializer = 'bee.gov.binding:delivery_local' WHERE materializer = 'bee.gov:delivery_local';
UPDATE bee_credential_projections SET materializer = 'bee.gov.delivery:delivery_protocol' WHERE materializer = 'bee.gov:delivery_protocol';
UPDATE bee_credential_projections SET materializer = 'bee.gov.env:environment' WHERE materializer = 'bee.gov:environment';
UPDATE bee_credential_projections SET materializer = 'bee.gov.activation:governed_application_admission' WHERE materializer = 'bee.gov:governed_application_admission';
UPDATE bee_credential_projections SET materializer = 'bee.gov.activation:headless_revert' WHERE materializer = 'bee.gov:headless_revert';
UPDATE bee_credential_projections SET materializer = 'bee.gov.delivery:hub_resolver' WHERE materializer = 'bee.gov:hub_resolver';
UPDATE bee_credential_projections SET materializer = 'bee.gov.delivery:lease_model' WHERE materializer = 'bee.gov:lease_model';
UPDATE bee_credential_projections SET materializer = 'bee.gov.activation:lists' WHERE materializer = 'bee.gov:lists';
UPDATE bee_credential_projections SET materializer = 'bee.gov.delivery:materializer' WHERE materializer = 'bee.gov:materializer';
UPDATE bee_credential_projections SET materializer = 'bee.gov.activation:migration_work' WHERE materializer = 'bee.gov:migration_work';
UPDATE bee_credential_projections SET materializer = 'bee.gov.env:node_identity_migration_source' WHERE materializer = 'bee.gov:node_identity_migration_source';
UPDATE bee_credential_projections SET materializer = 'bee.gov.binding:overlay_local' WHERE materializer = 'bee.gov:overlay_local';
UPDATE bee_credential_projections SET materializer = 'bee.gov.delivery:overlay_resolver' WHERE materializer = 'bee.gov:overlay_resolver';
UPDATE bee_credential_projections SET materializer = 'bee.gov.activation:preflight' WHERE materializer = 'bee.gov:preflight';
UPDATE bee_credential_projections SET materializer = 'bee.gov.activation:protected_kernel' WHERE materializer = 'bee.gov:protected_kernel';
UPDATE bee_credential_projections SET materializer = 'bee.gov.delivery:publication_profile_decoder' WHERE materializer = 'bee.gov:publication_profile_decoder';
UPDATE bee_credential_projections SET materializer = 'bee.gov.env:publication_profiles_ref' WHERE materializer = 'bee.gov:publication_profiles_ref';
UPDATE bee_credential_projections SET materializer = 'bee.gov.delivery:resolver' WHERE materializer = 'bee.gov:resolver';
UPDATE bee_credential_projections SET materializer = 'bee.gov.delivery:staging_resources' WHERE materializer = 'bee.gov:staging_resources';
UPDATE bee_credential_projections SET materializer = 'bee.gov.activation:super_edit' WHERE materializer = 'bee.gov:super_edit';
UPDATE bee_credential_projections SET materializer = 'bee.gov.workspace:workspace' WHERE materializer = 'bee.gov:workspace';
UPDATE bee_credential_projections SET materializer = 'bee.gov.workspace:workspace_applications' WHERE materializer = 'bee.gov:workspace_applications';
UPDATE bee_credential_projections SET materializer = 'bee.gov.env:workspace_folder_policy_ref' WHERE materializer = 'bee.gov:workspace_folder_policy_ref';
UPDATE bee_credential_projections SET materializer = 'bee.gov.env:workspace_folder_read_ref' WHERE materializer = 'bee.gov:workspace_folder_read_ref';
UPDATE bee_credential_projections SET materializer = 'bee.gov.workspace:workspace_protocol' WHERE materializer = 'bee.gov:workspace_protocol';
UPDATE bee_credential_projections SET materializer = 'bee.harness.binding:capabilities' WHERE materializer = 'bee.harness.carrier:capabilities';
UPDATE bee_credential_projections SET materializer = 'bee.harness.service:carrier' WHERE materializer = 'bee.harness.carrier:process';
UPDATE bee_credential_projections SET materializer = 'bee.harness:types' WHERE materializer = 'bee.harness.carrier:types';
UPDATE bee_credential_projections SET materializer = 'bee.harness.binding:admit' WHERE materializer = 'bee.harness.launch:admit';
UPDATE bee_credential_projections SET materializer = 'bee.harness.binding:locate_probe' WHERE materializer = 'bee.harness.launch:locate_probe';
UPDATE bee_credential_projections SET materializer = 'bee.harness.binding:present' WHERE materializer = 'bee.harness.launch:present';
UPDATE bee_credential_projections SET materializer = 'bee.harness.binding:resolve' WHERE materializer = 'bee.harness.launch:resolve';
UPDATE bee_credential_projections SET materializer = 'bee.harness.binding:setup' WHERE materializer = 'bee.harness.launch:setup';
UPDATE bee_credential_projections SET materializer = 'bee.harness.binding:setup_backend' WHERE materializer = 'bee.harness.launch:setup_backend';
UPDATE bee_credential_projections SET materializer = 'bee.harness.binding:start' WHERE materializer = 'bee.harness.launch:start';
UPDATE bee_credential_projections SET materializer = 'bee.harness.binding:call' WHERE materializer = 'bee.harness.profiles:call';
UPDATE bee_credential_projections SET materializer = 'bee.harness:profiles' WHERE materializer = 'bee.harness.profiles:contract';
UPDATE bee_credential_projections SET materializer = 'bee.harness.binding:profiles_local' WHERE materializer = 'bee.harness.profiles:local';
UPDATE bee_credential_projections SET materializer = 'bee.harness.env:carrier_host_ref' WHERE materializer = 'bee.harness:carrier_host_ref';
UPDATE bee_credential_projections SET materializer = 'bee.harness.api:gateway_hook' WHERE materializer = 'bee.harness:gateway_hook';
UPDATE bee_credential_projections SET materializer = 'bee.harness.api:gateway_hook_mcp' WHERE materializer = 'bee.harness:gateway_hook_mcp';
UPDATE bee_credential_projections SET materializer = 'bee.harness.api:gateway_hook_status' WHERE materializer = 'bee.harness:gateway_hook_status';
UPDATE bee_credential_projections SET materializer = 'bee.harness.launch:harness_activation' WHERE materializer = 'bee.harness:harness_activation';
UPDATE bee_credential_projections SET materializer = 'bee.harness.launch:harness_setup' WHERE materializer = 'bee.harness:harness_setup';
UPDATE bee_credential_projections SET materializer = 'bee.harness.binding:profiles_local' WHERE materializer = 'bee.harness:profiles_local';
UPDATE bee_credential_projections SET materializer = 'bee.hive.manager.security:client_policy' WHERE materializer = 'bee.hive.manager:client_policy';
UPDATE bee_credential_projections SET materializer = 'bee.hive.manager.app:directory' WHERE materializer = 'bee.hive.manager:directory';
UPDATE bee_credential_projections SET materializer = 'bee.hive.manager.app:names' WHERE materializer = 'bee.hive.manager:names';
UPDATE bee_credential_projections SET materializer = 'bee.hive.manager.security:viewer_policy' WHERE materializer = 'bee.hive.manager:viewer_policy';
UPDATE bee_credential_projections SET materializer = 'bee.hive.telemetry.binding:catalog_list' WHERE materializer = 'bee.hive.telemetry:catalog_list';
UPDATE bee_credential_projections SET materializer = 'bee.hive.telemetry.binding:cluster' WHERE materializer = 'bee.hive.telemetry:cluster';
UPDATE bee_credential_projections SET materializer = 'bee.hive.telemetry.binding:holdings' WHERE materializer = 'bee.hive.telemetry:holdings';
UPDATE bee_credential_projections SET materializer = 'bee.hive.telemetry.binding:presence' WHERE materializer = 'bee.hive.telemetry:presence';
UPDATE bee_credential_projections SET materializer = 'bee.hive.telemetry.binding:sampling' WHERE materializer = 'bee.hive.telemetry:sampling';
UPDATE bee_credential_projections SET materializer = 'bee.hive.telemetry.binding:stats' WHERE materializer = 'bee.hive.telemetry:stats';
UPDATE bee_credential_projections SET materializer = 'bee.hive.exposure:catalog' WHERE materializer = 'bee.hive:catalog';
UPDATE bee_credential_projections SET materializer = 'bee.hive.binding:client' WHERE materializer = 'bee.hive:client';
UPDATE bee_credential_projections SET materializer = 'bee.hive.binding:invoke_check' WHERE materializer = 'bee.hive:invoke_check';
UPDATE bee_credential_projections SET materializer = 'bee.hive.binding:output' WHERE materializer = 'bee.hive:output';
UPDATE bee_credential_projections SET materializer = 'bee.hive.security:principals' WHERE materializer = 'bee.hive:principals';
UPDATE bee_credential_projections SET materializer = 'bee.hive.workspace:workspace_query' WHERE materializer = 'bee.hive:workspace_query';
UPDATE bee_credential_projections SET materializer = 'bee.host.processes.app:probe' WHERE materializer = 'bee.host.processes:probe';
UPDATE bee_credential_projections SET materializer = 'bee.hub.modules.security:client_policy' WHERE materializer = 'bee.hub.modules:client_policy';
UPDATE bee_credential_projections SET materializer = 'bee.hub.modules.security:hub_policy' WHERE materializer = 'bee.hub.modules:hub_policy';
UPDATE bee_credential_projections SET materializer = 'bee.hub.modules.security:publication_policy' WHERE materializer = 'bee.hub.modules:publication_policy';
UPDATE bee_credential_projections SET materializer = 'bee.hub.modules.security:self_update_policy' WHERE materializer = 'bee.hub.modules:self_update_policy';
UPDATE bee_credential_projections SET materializer = 'bee.hub.package:binary_identity' WHERE materializer = 'bee.hub:binary_identity';
UPDATE bee_credential_projections SET materializer = 'bee.hub.package:graph' WHERE materializer = 'bee.hub:graph';
UPDATE bee_credential_projections SET materializer = 'bee.hub.activation:host_resources' WHERE materializer = 'bee.hub:host_resources';
UPDATE bee_credential_projections SET materializer = 'bee.hub.package:inspection' WHERE materializer = 'bee.hub:inspection';
UPDATE bee_credential_projections SET materializer = 'bee.hub.activation:installation' WHERE materializer = 'bee.hub:installation';
UPDATE bee_credential_projections SET materializer = 'bee.hub.package:inventory' WHERE materializer = 'bee.hub:inventory';
UPDATE bee_credential_projections SET materializer = 'bee.hub.package:inventory_reader' WHERE materializer = 'bee.hub:inventory_reader';
UPDATE bee_credential_projections SET materializer = 'bee.hub.activation:migration_work' WHERE materializer = 'bee.hub:migration_work';
UPDATE bee_credential_projections SET materializer = 'bee.hub.activation:migrations' WHERE materializer = 'bee.hub:migrations';
UPDATE bee_credential_projections SET materializer = 'bee.hub.package:native_compat' WHERE materializer = 'bee.hub:native_compat';
UPDATE bee_credential_projections SET materializer = 'bee.hub.package:plan' WHERE materializer = 'bee.hub:plan';
UPDATE bee_credential_projections SET materializer = 'bee.hub.env:process_host_ref' WHERE materializer = 'bee.hub:process_host_ref';
UPDATE bee_credential_projections SET materializer = 'bee.hub.env:publish_configuration_ref' WHERE materializer = 'bee.hub:publish_configuration_ref';
UPDATE bee_credential_projections SET materializer = 'bee.hub.publication:publish_executor' WHERE materializer = 'bee.hub:publish_executor';
UPDATE bee_credential_projections SET materializer = 'bee.hub.env:publish_executor_ref' WHERE materializer = 'bee.hub:publish_executor_ref';
UPDATE bee_credential_projections SET materializer = 'bee.hub.publication:publishing' WHERE materializer = 'bee.hub:publishing';
UPDATE bee_credential_projections SET materializer = 'bee.hub.package:requirements' WHERE materializer = 'bee.hub:requirements';
UPDATE bee_credential_projections SET materializer = 'bee.hub.package:result' WHERE materializer = 'bee.hub:result';
UPDATE bee_credential_projections SET materializer = 'bee.hub.package:semver' WHERE materializer = 'bee.hub:semver';
UPDATE bee_credential_projections SET materializer = 'bee.node.env:database_ref' WHERE materializer = 'bee.node:database_ref';
UPDATE bee_credential_projections SET materializer = 'bee.node.env:db' WHERE materializer = 'bee.node:db';
UPDATE bee_credential_projections SET materializer = 'bee.node.env:db_path' WHERE materializer = 'bee.node:db_path';
UPDATE bee_credential_projections SET materializer = 'bee.node.env:environment' WHERE materializer = 'bee.node:environment';
UPDATE bee_credential_projections SET materializer = 'bee.node.env:resources' WHERE materializer = 'bee.node:resources';
UPDATE bee_credential_projections SET materializer = 'bee.persist.persist:database' WHERE materializer = 'bee.persist:database';
UPDATE bee_credential_projections SET materializer = 'bee.persist.persist:ledger' WHERE materializer = 'bee.persist:ledger';
UPDATE bee_credential_projections SET materializer = 'bee.persist.persist:transaction' WHERE materializer = 'bee.persist:transaction';
UPDATE bee_credential_projections SET materializer = 'bee.placement.docker.env:boot_environment' WHERE materializer = 'bee.placement.docker:boot_environment';
UPDATE bee_credential_projections SET materializer = 'bee.placement.docker.profiles:coding' WHERE materializer = 'bee.placement.docker:coding';
UPDATE bee_credential_projections SET materializer = 'bee.placement.docker.profiles:coding_recipe' WHERE materializer = 'bee.placement.docker:coding_recipe';
UPDATE bee_credential_projections SET materializer = 'bee.placement.docker.env:environment' WHERE materializer = 'bee.placement.docker:environment';
UPDATE bee_credential_projections SET materializer = 'bee.placement.docker.env:environment_configuration' WHERE materializer = 'bee.placement.docker:environment_configuration';
UPDATE bee_credential_projections SET materializer = 'bee.placement.docker.binding:spec' WHERE materializer = 'bee.placement.docker:spec';
UPDATE bee_credential_projections SET materializer = 'bee.placement.native.env:admitted_roots_ref' WHERE materializer = 'bee.placement.native:admitted_roots_ref';
UPDATE bee_credential_projections SET materializer = 'bee.placement.native.env:configuration' WHERE materializer = 'bee.placement.native:configuration';
UPDATE bee_credential_projections SET materializer = 'bee.placement.native.env:database_ref' WHERE materializer = 'bee.placement.native:database_ref';
UPDATE bee_credential_projections SET materializer = 'bee.placement.native.env:db' WHERE materializer = 'bee.placement.native:db';
UPDATE bee_credential_projections SET materializer = 'bee.placement.native.env:db_path' WHERE materializer = 'bee.placement.native:db_path';
UPDATE bee_credential_projections SET materializer = 'bee.placement.native.env:environment' WHERE materializer = 'bee.placement.native:environment';
UPDATE bee_credential_projections SET materializer = 'bee.placement.native.env:executor_ref' WHERE materializer = 'bee.placement.native:executor_ref';
UPDATE bee_credential_projections SET materializer = 'bee.placement.native.env:host_files_ref' WHERE materializer = 'bee.placement.native:host_files_ref';
UPDATE bee_credential_projections SET materializer = 'bee.placement.native.env:placement_admitted_roots' WHERE materializer = 'bee.placement.native:placement_admitted_roots';
UPDATE bee_credential_projections SET materializer = 'bee.placement.native.env:placement_executor' WHERE materializer = 'bee.placement.native:placement_executor';
UPDATE bee_credential_projections SET materializer = 'bee.placement.native.env:placement_host_files' WHERE materializer = 'bee.placement.native:placement_host_files';
UPDATE bee_credential_projections SET materializer = 'bee.placement.native.env:placement_path' WHERE materializer = 'bee.placement.native:placement_path';
UPDATE bee_credential_projections SET materializer = 'bee.placement.native.env:placement_resource_mode' WHERE materializer = 'bee.placement.native:placement_resource_mode';
UPDATE bee_credential_projections SET materializer = 'bee.placement.native.env:placement_workdir_preparers' WHERE materializer = 'bee.placement.native:placement_workdir_preparers';
UPDATE bee_credential_projections SET materializer = 'bee.placement.native.binding:process_backend' WHERE materializer = 'bee.placement.native:process_backend';
UPDATE bee_credential_projections SET materializer = 'bee.placement.native.service:process_runner' WHERE materializer = 'bee.placement.native:process_runner';
UPDATE bee_credential_projections SET materializer = 'bee.placement.native.env:resource_mode_ref' WHERE materializer = 'bee.placement.native:resource_mode_ref';
UPDATE bee_credential_projections SET materializer = 'bee.placement.native.env:resources' WHERE materializer = 'bee.placement.native:resources';
UPDATE bee_credential_projections SET materializer = 'bee.placement.native.env:root' WHERE materializer = 'bee.placement.native:root';
UPDATE bee_credential_projections SET materializer = 'bee.placement.native.env:root_path' WHERE materializer = 'bee.placement.native:root_path';
UPDATE bee_credential_projections SET materializer = 'bee.placement.native.env:root_ref' WHERE materializer = 'bee.placement.native:root_ref';
UPDATE bee_credential_projections SET materializer = 'bee.placement.native.env:runner_host_ref' WHERE materializer = 'bee.placement.native:runner_host_ref';
UPDATE bee_credential_projections SET materializer = 'bee.placement.native.env:workdir_preparers_ref' WHERE materializer = 'bee.placement.native:workdir_preparers_ref';
UPDATE bee_credential_projections SET materializer = 'bee.placement.profiles:native' WHERE materializer = 'bee.placement:native';
UPDATE bee_credential_projections SET materializer = 'bee.placement.profiles:paths' WHERE materializer = 'bee.placement:paths';
UPDATE bee_credential_projections SET materializer = 'bee.placement.profiles:profiles' WHERE materializer = 'bee.placement:profiles';
UPDATE bee_credential_projections SET materializer = 'bee.placement.binding:resolver' WHERE materializer = 'bee.placement:resolver';
UPDATE bee_credential_projections SET materializer = 'bee.resources.env:database_ref' WHERE materializer = 'bee.resources:database_ref';
UPDATE bee_credential_projections SET materializer = 'bee.resources.env:db' WHERE materializer = 'bee.resources:db';
UPDATE bee_credential_projections SET materializer = 'bee.resources.env:db_path' WHERE materializer = 'bee.resources:db_path';
UPDATE bee_credential_projections SET materializer = 'bee.resources.env:environment' WHERE materializer = 'bee.resources:environment';
UPDATE bee_credential_projections SET materializer = 'bee.resources.binding:local' WHERE materializer = 'bee.resources:local';
UPDATE bee_credential_projections SET materializer = 'bee.resources.env:node_identity_migration_source' WHERE materializer = 'bee.resources:node_identity_migration_source';
UPDATE bee_credential_projections SET materializer = 'bee.resources.env:resource_roots' WHERE materializer = 'bee.resources:resource_roots';
UPDATE bee_credential_projections SET materializer = 'bee.resources.env:resources' WHERE materializer = 'bee.resources:resources';
UPDATE bee_credential_projections SET materializer = 'bee.resources.binding:resources_workspace_extension' WHERE materializer = 'bee.resources:resources_workspace_extension';
UPDATE bee_credential_projections SET materializer = 'bee.resources.env:roots_ref' WHERE materializer = 'bee.resources:roots_ref';
UPDATE bee_credential_projections SET materializer = 'bee.sessions.executor:driver_route' WHERE materializer = 'bee.sessions:driver_route';
UPDATE bee_credential_projections SET materializer = 'bee.sessions.executor:executor_registry' WHERE materializer = 'bee.sessions:executor_registry';
UPDATE bee_credential_projections SET materializer = 'bee.sessions.executor:executor_selection' WHERE materializer = 'bee.sessions:executor_selection';
UPDATE bee_credential_projections SET materializer = 'bee.sessions.service:owner' WHERE materializer = 'bee.sessions:owner';
UPDATE bee_credential_projections SET materializer = 'bee.sessions.binding:threads_journal' WHERE materializer = 'bee.sessions:threads_journal';
UPDATE bee_credential_projections SET materializer = 'bee.sessions.env:threads_journal_ref' WHERE materializer = 'bee.sessions:threads_journal_ref';
UPDATE bee_credential_projections SET materializer = 'bee.settings.app:build_info' WHERE materializer = 'bee.settings:build_info';
UPDATE bee_credential_projections SET materializer = 'bee.sync.binding:admit' WHERE materializer = 'bee.sync.hive:admit';
UPDATE bee_credential_projections SET materializer = 'bee.sync.values:bounds' WHERE materializer = 'bee.sync:bounds';
UPDATE bee_credential_projections SET materializer = 'bee.sync.values:canonical' WHERE materializer = 'bee.sync:canonical';
UPDATE bee_credential_projections SET materializer = 'bee.sync.env:database_ref' WHERE materializer = 'bee.sync:database_ref';
UPDATE bee_credential_projections SET materializer = 'bee.sync.env:db' WHERE materializer = 'bee.sync:db';
UPDATE bee_credential_projections SET materializer = 'bee.sync.env:db_path' WHERE materializer = 'bee.sync:db_path';
UPDATE bee_credential_projections SET materializer = 'bee.sync.env:environment' WHERE materializer = 'bee.sync:environment';
UPDATE bee_credential_projections SET materializer = 'bee.sync.env:exports_ref' WHERE materializer = 'bee.sync:exports_ref';
UPDATE bee_credential_projections SET materializer = 'bee.sync.env:resources' WHERE materializer = 'bee.sync:resources';
UPDATE bee_credential_projections SET materializer = 'bee.sync.values:version' WHERE materializer = 'bee.sync:version';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:append' WHERE materializer = 'bee.threads.approvals:append';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:cancel_intent' WHERE materializer = 'bee.threads.carrier:cancel_intent';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:cancel_status' WHERE materializer = 'bee.threads.carrier:cancel_status';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:checkpoint' WHERE materializer = 'bee.threads.carrier:checkpoint';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:claim' WHERE materializer = 'bee.threads.carrier:claim';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:commit' WHERE materializer = 'bee.threads.carrier:commit';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:ack' WHERE materializer = 'bee.threads.delivery:ack';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:ack_page' WHERE materializer = 'bee.threads.delivery:ack_page';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:delivery_claim' WHERE materializer = 'bee.threads.delivery:claim';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:close_subscription' WHERE materializer = 'bee.threads.delivery:close_subscription';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:dispatch' WHERE materializer = 'bee.threads.delivery:dispatch';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:expire' WHERE materializer = 'bee.threads.delivery:expire';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:forget_subscription' WHERE materializer = 'bee.threads.delivery:forget_subscription';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:page' WHERE materializer = 'bee.threads.delivery:page';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:reconcile' WHERE materializer = 'bee.threads.delivery:reconcile';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:release' WHERE materializer = 'bee.threads.delivery:release';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:resume' WHERE materializer = 'bee.threads.delivery:resume';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:subscribe' WHERE materializer = 'bee.threads.delivery:subscribe';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:unsubscribe' WHERE materializer = 'bee.threads.delivery:unsubscribe';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:wait' WHERE materializer = 'bee.threads.delivery:wait';
UPDATE bee_credential_projections SET materializer = 'bee.threads.service:waiter' WHERE materializer = 'bee.threads.delivery:waiter';
UPDATE bee_credential_projections SET materializer = 'bee.threads.service:waiter_service' WHERE materializer = 'bee.threads.delivery:waiter_service';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:watch' WHERE materializer = 'bee.threads.delivery:watch';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:recap_read' WHERE materializer = 'bee.threads.projection:recap_read';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:recap_rebuild' WHERE materializer = 'bee.threads.projection:recap_rebuild';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:recap_update' WHERE materializer = 'bee.threads.projection:recap_update';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:status_read' WHERE materializer = 'bee.threads.projection:status_read';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:status_rebuild' WHERE materializer = 'bee.threads.projection:status_rebuild';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:status_update' WHERE materializer = 'bee.threads.projection:status_update';
UPDATE bee_credential_projections SET materializer = 'bee.threads:record_types' WHERE materializer = 'bee.threads.records:types';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:admit_action' WHERE materializer = 'bee.threads.service:admit_action';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:close' WHERE materializer = 'bee.threads.service:close';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:create' WHERE materializer = 'bee.threads.service:create';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:end_turn' WHERE materializer = 'bee.threads.service:end_turn';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:feed_read' WHERE materializer = 'bee.threads.service:feed_read';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:fence_app' WHERE materializer = 'bee.threads.service:fence_app';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:get' WHERE materializer = 'bee.threads.service:get';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:inbox_accept' WHERE materializer = 'bee.threads.service:inbox_accept';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:inbox_ack' WHERE materializer = 'bee.threads.service:inbox_ack';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:inbox_describe' WHERE materializer = 'bee.threads.service:inbox_describe';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:inbox_list' WHERE materializer = 'bee.threads.service:inbox_list';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:inbox_offer' WHERE materializer = 'bee.threads.service:inbox_offer';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:inbox_outbox_claim' WHERE materializer = 'bee.threads.service:inbox_outbox_claim';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:inbox_outbox_settle' WHERE materializer = 'bee.threads.service:inbox_outbox_settle';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:inbox_reply' WHERE materializer = 'bee.threads.service:inbox_reply';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:inbox_resolve' WHERE materializer = 'bee.threads.service:inbox_resolve';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:inbox_send' WHERE materializer = 'bee.threads.service:inbox_send';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:inbox_transport' WHERE materializer = 'bee.threads.service:inbox_transport';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:join' WHERE materializer = 'bee.threads.service:join';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:leave' WHERE materializer = 'bee.threads.service:leave';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:list' WHERE materializer = 'bee.threads.service:list';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:list_workspace' WHERE materializer = 'bee.threads.service:list_workspace';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:notify' WHERE materializer = 'bee.threads.service:notify';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:operation_describe' WHERE materializer = 'bee.threads.service:operation_describe';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:operation_lookup' WHERE materializer = 'bee.threads.service:operation_lookup';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:prepare_attempt' WHERE materializer = 'bee.threads.service:prepare_attempt';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:read_after' WHERE materializer = 'bee.threads.service:read_after';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:receipt' WHERE materializer = 'bee.threads.service:receipt';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:record' WHERE materializer = 'bee.threads.service:record';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:register_app_alias' WHERE materializer = 'bee.threads.service:register_app_alias';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:request_turn' WHERE materializer = 'bee.threads.service:request_turn';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:retire_app_alias' WHERE materializer = 'bee.threads.service:retire_app_alias';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:send' WHERE materializer = 'bee.threads.service:send';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:send_status' WHERE materializer = 'bee.threads.service:send_status';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:session_attach' WHERE materializer = 'bee.threads.service:session_attach';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:session_create' WHERE materializer = 'bee.threads.service:session_create';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:session_describe' WHERE materializer = 'bee.threads.service:session_describe';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:session_scan' WHERE materializer = 'bee.threads.service:session_scan';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:session_transition' WHERE materializer = 'bee.threads.service:session_transition';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:start_attempt' WHERE materializer = 'bee.threads.service:start_attempt';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:turn_accept' WHERE materializer = 'bee.threads.service:turn_accept';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:turn_observation' WHERE materializer = 'bee.threads.service:turn_observation';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:turn_pull' WHERE materializer = 'bee.threads.service:turn_pull';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:turn_recover' WHERE materializer = 'bee.threads.service:turn_recover';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:turn_reserve' WHERE materializer = 'bee.threads.service:turn_reserve';
UPDATE bee_credential_projections SET materializer = 'bee.threads:types' WHERE materializer = 'bee.threads.service:types';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:work_cancel' WHERE materializer = 'bee.threads.service:work_cancel';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:work_describe' WHERE materializer = 'bee.threads.service:work_describe';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:work_history' WHERE materializer = 'bee.threads.service:work_history';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:work_scan' WHERE materializer = 'bee.threads.service:work_scan';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:work_send' WHERE materializer = 'bee.threads.service:work_send';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:work_settle' WHERE materializer = 'bee.threads.service:work_settle';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:work_uncertain' WHERE materializer = 'bee.threads.service:work_uncertain';
UPDATE bee_credential_projections SET materializer = 'bee.threads.timeline.security:client_policy' WHERE materializer = 'bee.threads.timeline:client_policy';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:approvals_local' WHERE materializer = 'bee.threads:approvals_local';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:authority_local' WHERE materializer = 'bee.threads:authority_local';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:capabilities' WHERE materializer = 'bee.threads:capabilities';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:capabilities_report' WHERE materializer = 'bee.threads:capabilities_report';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:carrier_local' WHERE materializer = 'bee.threads:carrier_local';
UPDATE bee_credential_projections SET materializer = 'bee.threads.env:database_path' WHERE materializer = 'bee.threads:database_path';
UPDATE bee_credential_projections SET materializer = 'bee.threads.env:database_ref' WHERE materializer = 'bee.threads:database_ref';
UPDATE bee_credential_projections SET materializer = 'bee.threads.env:db' WHERE materializer = 'bee.threads:db';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:delivery_local' WHERE materializer = 'bee.threads:delivery_local';
UPDATE bee_credential_projections SET materializer = 'bee.threads.env:environment' WHERE materializer = 'bee.threads:environment';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:journal_local' WHERE materializer = 'bee.threads:journal_local';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:lifecycle_local' WHERE materializer = 'bee.threads:lifecycle_local';
UPDATE bee_credential_projections SET materializer = 'bee.threads.service:owner' WHERE materializer = 'bee.threads:owner';
UPDATE bee_credential_projections SET materializer = 'bee.threads.service:owner_service' WHERE materializer = 'bee.threads:owner_service';
UPDATE bee_credential_projections SET materializer = 'bee.threads.binding:projection_local' WHERE materializer = 'bee.threads:projection_local';
UPDATE bee_credential_projections SET materializer = 'bee.threads.env:resources' WHERE materializer = 'bee.threads:resources';
UPDATE bee_credential_projections SET materializer = 'bee.workspace.manager.security:client_policy' WHERE materializer = 'bee.workspace.manager:client_policy';
UPDATE bee_credential_projections SET materializer = 'bee.security.approvals:approver_policies' WHERE materializer = 'bee:approver_policies';
UPDATE bee_credential_projections SET materializer = 'bee.security.capability:capability_catalog' WHERE materializer = 'bee:capability_catalog';
UPDATE bee_credential_projections SET materializer = 'bee.protocol:clock' WHERE materializer = 'bee:clock';
UPDATE bee_credential_projections SET materializer = 'bee.env:docs_corpus' WHERE materializer = 'bee:docs_corpus';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.api:gateway_endpoint' WHERE materializer = 'bee:gateway_endpoint';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.service:gateway_installation_service' WHERE materializer = 'bee:gateway_installation_service';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.api:gateway_listener' WHERE materializer = 'bee:gateway_listener';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.api:gateway_mcp' WHERE materializer = 'bee:gateway_mcp';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.service:gateway_publication_service' WHERE materializer = 'bee:gateway_publication_service';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.api:gateway_ready' WHERE materializer = 'bee:gateway_ready';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.api:gateway_router' WHERE materializer = 'bee:gateway_router';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.binding:gateway_workspace_extension' WHERE materializer = 'bee:gateway_workspace_extension';
UPDATE bee_credential_projections SET materializer = 'bee.gov.service:gov_recovery_service' WHERE materializer = 'bee:gov_recovery_service';
UPDATE bee_credential_projections SET materializer = 'bee.hive.supervisor:hive_operation_adapters' WHERE materializer = 'bee:hive_operation_adapters';
UPDATE bee_credential_projections SET materializer = 'bee.hub.publication:hub_publication' WHERE materializer = 'bee:hub_publication';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.env:module_installation' WHERE materializer = 'bee:module_installation';
UPDATE bee_credential_projections SET materializer = 'bee.gateway.env:module_publication' WHERE materializer = 'bee:module_publication';
UPDATE bee_credential_projections SET materializer = 'bee.security.gov:protected_kernel' WHERE materializer = 'bee:protected_kernel';
UPDATE bee_credential_projections SET materializer = 'bee.sync.service:sync_distribution_service' WHERE materializer = 'bee:sync_distribution_service';
UPDATE bee_credential_projections SET materializer = 'bee.sync.env:sync_exports' WHERE materializer = 'bee:sync_exports';
UPDATE bee_credential_projections SET materializer = 'bee.threads.service:thread_outbox_pump_service' WHERE materializer = 'bee:thread_outbox_pump_service';
UPDATE bee_credential_projections SET materializer = 'bee.placement.native.env:workdir_preparers' WHERE materializer = 'bee:workdir_preparers';
UPDATE bee_credential_projections SET materializer = 'bee.launch.service:workspace_hosts' WHERE materializer = 'bee:workspace_hosts';
UPDATE bee_credential_definitions SET source_ref = 'bee.app.status:startup_progress' WHERE source_ref = 'bee.app:startup_progress';
UPDATE bee_credential_definitions SET source_ref = 'bee.persist.env:startup_progress' WHERE source_ref = 'bee.persist:startup_progress';
UPDATE bee_credential_projections SET materializer = 'bee.app.status:startup_progress' WHERE materializer = 'bee.app:startup_progress';
UPDATE bee_credential_projections SET materializer = 'bee.persist.env:startup_progress' WHERE materializer = 'bee.persist:startup_progress';
]]
local HIVE_REFERENCES_SQL = [[
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.binding:inbox_sender' WHERE source_ref = 'bee.hive.service:inbox_sender';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.binding:replica_sender' WHERE source_ref = 'bee.hive.service:replica_sender';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.types:peers' WHERE source_ref = 'bee.hive.supervisor:peers';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.types:registration' WHERE source_ref = 'bee.hive.supervisor:registration';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.types:enrollment' WHERE source_ref = 'bee.hive.supervisor:enrollment';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.types:invites' WHERE source_ref = 'bee.hive.supervisor:invites';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.binding:admission' WHERE source_ref = 'bee.hive.supervisor:admission';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.service:supervisor' WHERE source_ref = 'bee.hive.supervisor:main';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.types:owner_stop' WHERE source_ref = 'bee.hive.supervisor:owner_stop';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.types:workspace_commands' WHERE source_ref = 'bee.hive.supervisor:workspace_commands';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.binding:workspace_command' WHERE source_ref = 'bee.hive.supervisor:workspace_command';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.binding:advertise' WHERE source_ref = 'bee.hive.supervisor:advertise';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.types:audiences' WHERE source_ref = 'bee.hive.supervisor:audiences';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.binding:policy_admission' WHERE source_ref = 'bee.hive.supervisor:policy_admission';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.binding:admit_policy' WHERE source_ref = 'bee.hive.supervisor:admit_policy';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.types:adapters' WHERE source_ref = 'bee.hive.supervisor:adapters';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.binding:dispatch' WHERE source_ref = 'bee.hive.supervisor:dispatch';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.binding:execute' WHERE source_ref = 'bee.hive.supervisor:execute';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.binding:workspaces' WHERE source_ref = 'bee.hive.api:workspaces';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.types:workspaces_page' WHERE source_ref = 'bee.hive.api:workspaces_page';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.types:workspace_query' WHERE source_ref = 'bee.hive.workspace:workspace_query';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.service:display_command' WHERE source_ref = 'bee.hive.desktop:command';
UPDATE bee_credential_definitions SET source_ref = 'bee.hive.service:viewer' WHERE source_ref = 'bee.hive.desktop:viewer';
UPDATE bee_credential_projections SET materializer = 'bee.hive.binding:inbox_sender' WHERE materializer = 'bee.hive.service:inbox_sender';
UPDATE bee_credential_projections SET materializer = 'bee.hive.binding:replica_sender' WHERE materializer = 'bee.hive.service:replica_sender';
UPDATE bee_credential_projections SET materializer = 'bee.hive.types:peers' WHERE materializer = 'bee.hive.supervisor:peers';
UPDATE bee_credential_projections SET materializer = 'bee.hive.types:registration' WHERE materializer = 'bee.hive.supervisor:registration';
UPDATE bee_credential_projections SET materializer = 'bee.hive.types:enrollment' WHERE materializer = 'bee.hive.supervisor:enrollment';
UPDATE bee_credential_projections SET materializer = 'bee.hive.types:invites' WHERE materializer = 'bee.hive.supervisor:invites';
UPDATE bee_credential_projections SET materializer = 'bee.hive.binding:admission' WHERE materializer = 'bee.hive.supervisor:admission';
UPDATE bee_credential_projections SET materializer = 'bee.hive.service:supervisor' WHERE materializer = 'bee.hive.supervisor:main';
UPDATE bee_credential_projections SET materializer = 'bee.hive.types:owner_stop' WHERE materializer = 'bee.hive.supervisor:owner_stop';
UPDATE bee_credential_projections SET materializer = 'bee.hive.types:workspace_commands' WHERE materializer = 'bee.hive.supervisor:workspace_commands';
UPDATE bee_credential_projections SET materializer = 'bee.hive.binding:workspace_command' WHERE materializer = 'bee.hive.supervisor:workspace_command';
UPDATE bee_credential_projections SET materializer = 'bee.hive.binding:advertise' WHERE materializer = 'bee.hive.supervisor:advertise';
UPDATE bee_credential_projections SET materializer = 'bee.hive.types:audiences' WHERE materializer = 'bee.hive.supervisor:audiences';
UPDATE bee_credential_projections SET materializer = 'bee.hive.binding:policy_admission' WHERE materializer = 'bee.hive.supervisor:policy_admission';
UPDATE bee_credential_projections SET materializer = 'bee.hive.binding:admit_policy' WHERE materializer = 'bee.hive.supervisor:admit_policy';
UPDATE bee_credential_projections SET materializer = 'bee.hive.types:adapters' WHERE materializer = 'bee.hive.supervisor:adapters';
UPDATE bee_credential_projections SET materializer = 'bee.hive.binding:dispatch' WHERE materializer = 'bee.hive.supervisor:dispatch';
UPDATE bee_credential_projections SET materializer = 'bee.hive.binding:execute' WHERE materializer = 'bee.hive.supervisor:execute';
UPDATE bee_credential_projections SET materializer = 'bee.hive.binding:workspaces' WHERE materializer = 'bee.hive.api:workspaces';
UPDATE bee_credential_projections SET materializer = 'bee.hive.types:workspaces_page' WHERE materializer = 'bee.hive.api:workspaces_page';
UPDATE bee_credential_projections SET materializer = 'bee.hive.types:workspace_query' WHERE materializer = 'bee.hive.workspace:workspace_query';
UPDATE bee_credential_projections SET materializer = 'bee.hive.service:display_command' WHERE materializer = 'bee.hive.desktop:command';
UPDATE bee_credential_projections SET materializer = 'bee.hive.service:viewer' WHERE materializer = 'bee.hive.desktop:viewer';
]]
local list: {Migration} = {
    {id = 1, name = "credentials", sql = CREDENTIALS_SQL, rebuild = false},
    {id = 2, name = "file_sources", sql = FILE_SOURCES_SQL, rebuild = true},
    {id = 3, name = "optional_files", sql = "ALTER TABLE bee_credential_definitions ADD COLUMN optional INTEGER NOT NULL DEFAULT 0 CHECK(optional IN (0,1));", rebuild = false},
    {id = 4, name = "declared_providers", sql = DECLARED_PROVIDERS_SQL, rebuild = true},
    {id = 5, name = "frozen_formats", sql = FROZEN_FORMATS_SQL, rebuild = false},
    {id = 6, name = "credentials_node_identity", sql = NODE_IDENTITY_SQL, rebuild = false},
    {id = 7, name = "root_namespace_references", sql = ROOT_REFERENCES_SQL, rebuild = false},
        {id = 8, name = "hive_component_references", sql = HIVE_REFERENCES_SQL, rebuild = false},
}
function M.all(): {Migration}
    return list
end
return M
