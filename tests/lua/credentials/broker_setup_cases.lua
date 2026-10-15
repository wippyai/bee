-- MIT. Focused broker test cases.
local test = require("test")
local bounds = require("bounds")
local principals = require("principals")
local registry = require("registry")
local fs = require("fs")
local support = require("support")
local OTHER = support.OTHER
local USER = support.USER
local CODEX_LOGIN_SOURCE = support.CODEX_LOGIN_SOURCE
local CLAUDE_LOGIN_SOURCE = support.CLAUDE_LOGIN_SOURCE
local INVALID_LOGIN_SOURCE = support.INVALID_LOGIN_SOURCE
local MISSING_LOGIN_SOURCE = support.MISSING_LOGIN_SOURCE
local UNPRIVILEGED_LOGIN_SOURCE = support.UNPRIVILEGED_LOGIN_SOURCE
local UNREADABLE_LOGIN_SOURCE = support.UNREADABLE_LOGIN_SOURCE
local AGY_ONBOARDING = support.AGY_ONBOARDING
local GROK_CONFIG = support.GROK_CONFIG
local GROK_PRIVATE_BASE = support.GROK_PRIVATE_BASE
local GROK_CONFIG_SENTINEL = support.GROK_CONFIG_SENTINEL
local CODEX_FILE_SENTINEL = support.CODEX_FILE_SENTINEL
local CLAUDE_FILE_SENTINEL = support.CLAUDE_FILE_SENTINEL
local GROK_FILE_SENTINEL = support.GROK_FILE_SENTINEL
local DIGEST = support.DIGEST
local fresh = support.fresh
local caller = support.caller
local bound = support.bound
local manager = support.manager
local user = support.user
local other = support.other
local runner = support.runner
local outsider = support.outsider
local call = support.call
local value = support.value
local code = support.code
local clean = support.clean
local write_file = support.write_file
local has = support.has
local admit_sources = support.admit_sources
local issue = support.issue
local M = {}
function M.define(workspace: string)
    test.it("resolves optional setup files transiently with bounds and preserves the credential revision", function()
        local ws = fresh("agy-setup")
        admit_sources(ws)
        write_file(CODEX_LOGIN_SOURCE, "antigravity-oauth-token", "opaque-login-bytes")
        write_file(CODEX_LOGIN_SOURCE, AGY_ONBOARDING, '{"consumerOnboardingComplete":true}')
        local definition = value(call(manager, "define", {workspace_id = ws, name = "agy_setup", provider = "agy",
            source = {kind = "fs_directory", ref = CODEX_LOGIN_SOURCE}, optional = true}))
        local digest, revision = definition.digest, definition.revision
        local attempt = fresh("attempt")
        local projection = issue(user, ws, "agy_setup", attempt)
        local present = value(call(runner, "materialize", {projection_id = projection.projection_id, subject = USER, audience = USER,
            attempt_id = attempt, generation_key = "agy-setup-present"}))
        test.eq(present.format.file.initialize[1].path, AGY_ONBOARDING)
        test.eq(present.format.file.initialize[1].content, '{"consumerOnboardingComplete":true}')
        local volume = fs.get(CODEX_LOGIN_SOURCE)
        if not volume then error("setup source volume unavailable") end
        local removed, remove_error = volume:remove(AGY_ONBOARDING)
        if not removed then error("remove setup file: " .. tostring(remove_error)) end
        local absent = value(call(runner, "materialize", {projection_id = projection.projection_id, subject = USER, audience = USER,
            attempt_id = attempt, generation_key = "agy-setup-absent"}))
        test.eq(#absent.format.file.initialize, 0)
        write_file(CODEX_LOGIN_SOURCE, AGY_ONBOARDING, "not-json")
        test.eq(code(call(runner, "materialize", {projection_id = projection.projection_id, subject = USER, audience = USER,
            attempt_id = attempt, generation_key = "agy-setup-invalid"})), "INVALID")
        write_file(CODEX_LOGIN_SOURCE, AGY_ONBOARDING, string.rep("x", 4097))
        test.eq(code(call(runner, "materialize", {projection_id = projection.projection_id, subject = USER, audience = USER,
            attempt_id = attempt, generation_key = "agy-setup-oversized"})), "INVALID")
        local entry = registry.get("bee.credentials.env:credential_sources")
        if not entry then error("credential sources entry") end
        for _, item in ipairs(principals.objects((assert(bounds.object(entry.data))).sources)) do
            if item.provider == "agy" then item.setup_path = nil end
        end
        local changes = registry.snapshot():changes()
        changes:update(entry)
        local applied, apply_error = changes:apply()
        if not applied then error("remove setup admission: " .. tostring(apply_error)) end
        local revoked_setup = call(runner, "materialize", {projection_id = projection.projection_id, subject = USER, audience = USER,
            attempt_id = attempt, generation_key = "agy-setup-revoked"})
        test.eq(code(revoked_setup), "CONFLICT")
        test.is_true(tostring(revoked_setup.error and revoked_setup.error.message):find("credential source changed", 1, true) ~= nil)
        clean(revoked_setup)
        local listed = value(call(manager, "list", {workspace_id = ws}))
        local definitions = principals.objects(listed.definitions)
        local persisted: {[string]: unknown}? = nil
        for _, item in ipairs(definitions) do
            if item.name == "agy_setup" then persisted = item end
        end
        if not persisted then error("Agy setup definition disappeared") end
        test.eq(persisted.digest, digest)
        test.eq(persisted.revision, revision)
    end)
    test.it("does not synthesize an absent optional provider settings file", function()
        local ws = fresh("claude-settings-absent")
        admit_sources(ws)
        write_file(CLAUDE_LOGIN_SOURCE, ".credentials.json", CLAUDE_FILE_SENTINEL)
        local entry = registry.get("bee.credentials.env:credential_sources")
        if not entry then error("credential sources entry") end
        for _, item in ipairs(principals.objects((assert(bounds.object(entry.data))).sources)) do
            if item.ref == CLAUDE_LOGIN_SOURCE and item.provider == "claude" then
                item.setup_path = ".claude/settings.json"
                item.setup_destination = ".claude/settings.json"
                item.setup_content_format = "opaque"
            end
        end
        local changed = registry.snapshot():changes()
        changed:update(entry)
        local applied, apply_error = changed:apply()
        if not applied then error("admit Claude settings: " .. tostring(apply_error)) end
        value(call(manager, "define", {workspace_id = ws, name = "claude_login", provider = "claude",
            source = {kind = "fs_directory", ref = CLAUDE_LOGIN_SOURCE}, optional = true}))
        local attempt = fresh("claude-settings-attempt")
        local projection = issue(user, ws, "claude_login", attempt)
        local materialized = value(call(runner, "materialize", {projection_id = projection.projection_id, subject = USER, audience = USER,
            attempt_id = attempt, generation_key = "claude-settings-generation"}))
        test.eq(#materialized.format.file.initialize, 1)
        test.eq(materialized.format.file.initialize[1].path, ".claude.json")
    end)
    test.it("imports Grok configuration as an opaque private composition base with or without login", function()
        local ws = fresh("grok-setup")
        admit_sources(ws)
        write_file(CODEX_LOGIN_SOURCE, ".grok/auth.json", GROK_FILE_SENTINEL)
        write_file(CODEX_LOGIN_SOURCE, GROK_CONFIG, GROK_CONFIG_SENTINEL)
        local definition_reply = call(manager, "define", {workspace_id = ws, name = "grok_login", provider = "grok",
            source = {kind = "fs_directory", ref = CODEX_LOGIN_SOURCE}, optional = true})
        clean(definition_reply)
        local definition = value(definition_reply)
        local attempt = fresh("attempt")
        local projection_reply = call(user, "issue_projection", {workspace_id = ws, name = "grok_login", audience = USER,
            attempt_id = attempt, profile_id = "batch", profile_digest = DIGEST, binding_digest = DIGEST,
            launch_policy_digest = DIGEST, idempotency_key = fresh("grok-key")})
        clean(projection_reply)
        local projection = value(projection_reply)
        clean(call(runner, "check", {projection_id = projection.projection_id, subject = USER, audience = USER, attempt_id = attempt}))
        local present = value(call(runner, "materialize", {projection_id = projection.projection_id, subject = USER,
            audience = USER, attempt_id = attempt, generation_key = "grok-present"}))
        test.eq(present.value, GROK_FILE_SENTINEL)
        test.eq(present.format.file.initialize[1].path, GROK_PRIVATE_BASE)
        test.eq(present.format.file.initialize[1].content, GROK_CONFIG_SENTINEL)

        local volume = fs.get(CODEX_LOGIN_SOURCE)
        if not volume then error("Grok source volume unavailable") end
        local removed, remove_error = volume:remove(".grok/auth.json")
        if not removed then error("remove Grok login: " .. tostring(remove_error)) end
        local checked_absent = value(call(runner, "check", {projection_id = projection.projection_id, subject = USER,
            audience = USER, attempt_id = attempt}))
        test.eq(checked_absent.source_present, false)
        clean(call(runner, "check", {projection_id = projection.projection_id, subject = USER, audience = USER, attempt_id = attempt}))
        local absent = value(call(runner, "materialize", {projection_id = projection.projection_id, subject = USER,
            audience = USER, attempt_id = attempt, generation_key = "grok-absent"}))
        test.eq(absent.present, false)
        test.is_nil(absent.value)
        test.eq(absent.format.file.initialize[1].path, GROK_PRIVATE_BASE)
        test.eq(absent.format.file.initialize[1].content, GROK_CONFIG_SENTINEL)
        local removed_config, removed_config_error = volume:remove(GROK_CONFIG)
        if not removed_config then error("remove Grok config: " .. tostring(removed_config_error)) end
        local empty_base = value(call(runner, "materialize", {projection_id = projection.projection_id, subject = USER,
            audience = USER, attempt_id = attempt, generation_key = "grok-empty-base"}))
        test.eq(empty_base.present, false)
        test.eq(empty_base.format.file.initialize[1].path, GROK_PRIVATE_BASE)
        test.eq(empty_base.format.file.initialize[1].content, "")
        clean(call(manager, "list", {workspace_id = ws}))
    end)
    test.it("fences every changed setup descriptor field until explicit redefinition", function()
        local mutations = {
            {field = "setup_path", value = ".grok/other-config.toml"},
            {field = "setup_destination", value = ".grok/.other-private-base.toml"},
            {field = "setup_content_format", value = "json"},
            {field = "setup_initialize_empty", value = false},
        }
        for _, mutation in ipairs(mutations) do
            local ws = fresh("grok-setup-digest")
            admit_sources(ws)
            write_file(CODEX_LOGIN_SOURCE, ".grok/auth.json", GROK_FILE_SENTINEL)
            write_file(CODEX_LOGIN_SOURCE, GROK_CONFIG, GROK_CONFIG_SENTINEL)
            local definition = value(call(manager, "define", {workspace_id = ws, name = "grok_login", provider = "grok",
                source = {kind = "fs_directory", ref = CODEX_LOGIN_SOURCE}, optional = true}))
            local attempt = fresh("attempt")
            local projection = issue(user, ws, "grok_login", attempt)

            local entry = registry.get("bee.credentials.env:credential_sources")
            if not entry then error("credential sources entry") end
            local changed = false
            for _, item in ipairs(principals.objects((assert(bounds.object(entry.data))).sources)) do
                if item.provider == "grok" and item.workspace_id == ws then
                    item[mutation.field] = mutation.value
                    changed = true
                end
            end
            if not changed then error("Grok setup source was not found") end
            local changes = registry.snapshot():changes()
            changes:update(entry)
            local applied, apply_error = changes:apply()
            if not applied then error("change setup descriptor: " .. tostring(apply_error)) end

            local refused = call(runner, "materialize", {projection_id = projection.projection_id, subject = USER,
                audience = USER, attempt_id = attempt, generation_key = fresh("grok-mutated-setup")})
            test.eq(code(refused), "CONFLICT")
            test.is_true(tostring(refused.error and refused.error.message):find("credential source changed", 1, true) ~= nil)
            test.eq(definition.revision, 1)
            clean(refused)
        end
    end)
    test.it("rejects an unreadable optional login instead of treating it as absent", function()
        local ws = fresh("ws")
        admit_sources(ws)
        local attempt = fresh("attempt")
        value(call(manager, "define", {workspace_id = ws, name = "unreadable_login", provider = "codex",
            source = {kind = "fs_directory", ref = UNREADABLE_LOGIN_SOURCE}, optional = true}))
        local projection = issue(user, ws, "unreadable_login", attempt)
        local result = call(runner, "materialize", {projection_id = projection.projection_id, subject = USER,
            audience = USER, attempt_id = attempt, generation_key = fresh("gk")})
        test.eq(code(result), "UNAVAILABLE")
        test.is_true(tostring(result.error and result.error.message):find("denied", 1, true) ~= nil)
        clean(result)
    end)
    test.it("fails closed on missing, invalid, empty or oversized login files", function()
        local ws = fresh("ws")
        admit_sources(ws)
        local attempt = fresh("attempt")

        value(call(manager, "define", {workspace_id = ws, name = "missing_login", provider = "codex", source = {kind = "fs_directory", ref = MISSING_LOGIN_SOURCE}}))
        local missing_proj = issue(user, ws, "missing_login", attempt)
        local missing_res = call(runner, "materialize", {projection_id = missing_proj.projection_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = fresh("gk")})
        test.eq(code(missing_res), "UNAVAILABLE")

        local optional_name = "optional_missing_login"
        local optional_def = value(call(manager, "define", {workspace_id = ws, name = optional_name, provider = "codex", source = {kind = "fs_directory", ref = MISSING_LOGIN_SOURCE}, optional = true}))
        test.eq(optional_def.optional, true)
        local optional_proj = issue(user, ws, optional_name, attempt)
        local absent = value(call(runner, "materialize", {projection_id = optional_proj.projection_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "optional-g1"}))
        test.eq(absent.present, false)
        test.eq(absent.optional, true)
        test.eq(absent.generation, 1)
        test.is_nil(absent.value)
        test.eq(absent.definition_id, optional_def.definition_id)
        test.eq(absent.definition_revision, optional_def.revision)
        test.eq(code(call(runner, "materialize", {projection_id = optional_proj.projection_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "optional-g1"})), "CONFLICT")
        local absent_again = value(call(runner, "materialize", {projection_id = optional_proj.projection_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "optional-g2"}))
        test.eq(absent_again.present, false)
        test.eq(absent_again.optional, true)
        test.eq(absent_again.generation, 2)
        test.is_nil(absent_again.value)

        value(call(manager, "define", {workspace_id = ws, name = "invalid_login", provider = "codex", source = {kind = "fs_directory", ref = INVALID_LOGIN_SOURCE}}))
        local invalid_proj = issue(user, ws, "invalid_login", attempt)
        write_file(INVALID_LOGIN_SOURCE, "auth.json", 'not-valid-json-content')
        local bad_json_res = call(runner, "materialize", {projection_id = invalid_proj.projection_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = fresh("gk")})
        test.eq(code(bad_json_res), "INVALID")

        write_file(INVALID_LOGIN_SOURCE, "auth.json", '')
        local empty_res = call(runner, "materialize", {projection_id = invalid_proj.projection_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = fresh("gk")})
        test.eq(code(empty_res), "UNAVAILABLE")

        local huge = '{"token":"' .. string.rep("x", 65536) .. '"}'
        write_file(INVALID_LOGIN_SOURCE, "auth.json", huge)
        local huge_res = call(runner, "materialize", {projection_id = invalid_proj.projection_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = fresh("gk")})
        test.eq(code(huge_res), "INVALID")
    end)
    test.it("proves registry source metadata alone cannot grant FS read without host file policy", function()
        local ws = fresh("ws")
        admit_sources(ws)
        write_file(UNPRIVILEGED_LOGIN_SOURCE, "auth.json", CODEX_FILE_SENTINEL)
        local attempt = fresh("attempt")

        -- UNPRIVILEGED_LOGIN_SOURCE is present in bee.credentials.env:credential_sources allowlist metadata,
        -- but absent from bee.credentials.security:credential_file_policy resources.
        local defined = value(call(manager, "define", {workspace_id = ws, name = "unprivileged", provider = "codex", source = {kind = "fs_directory", ref = UNPRIVILEGED_LOGIN_SOURCE}}))
        test.eq(defined.destination, "auth.json")
        test.eq(defined.projection_kind, "file")
        clean(call(manager, "define", {workspace_id = ws, name = "unprivileged", provider = "codex", source = {kind = "fs_directory", ref = UNPRIVILEGED_LOGIN_SOURCE}}))

        local proj = issue(user, ws, "unprivileged", attempt)
        test.eq(proj.destination, "auth.json")
        test.eq(proj.projection_kind, "file")
        clean(call(user, "issue_projection", {workspace_id = ws, name = "unprivileged", audience = USER, attempt_id = attempt, profile_id = "batch", profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = fresh("key")}))

        local checked = call(runner, "check", {projection_id = proj.projection_id, subject = USER, audience = USER, attempt_id = attempt})
        test.eq(code(checked), "UNAVAILABLE")
        clean(call(runner, "check", {projection_id = proj.projection_id, subject = USER, audience = USER, attempt_id = attempt}))

        -- Materialization attempts to read via fs.get; fails closed because registry source metadata alone cannot grant filesystem access
        local res = call(runner, "materialize", {projection_id = proj.projection_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = fresh("gk")})
        test.eq(code(res), "UNAVAILABLE")
        clean(res)
    end)
    test.it("keeps source write authority off read-only credential endpoints", function()
        local read_policy = registry.get("bee.credentials.security:credential_file_policy")
        local write_policy = registry.get("bee.credentials.security:credential_file_write_policy")
        if not read_policy or not write_policy then error("credential file policies are unavailable") end
        local read_actions = (principals.strings((assert(bounds.object((assert(bounds.object(read_policy.data))).policy))).actions))
        local write_actions = (principals.strings((assert(bounds.object((assert(bounds.object(write_policy.data))).policy))).actions))
        test.is_true(has(read_actions, "fs.get"))
        test.is_true(has(read_actions, "fs.read"))
        test.is_false(has(read_actions, "fs.write"))
        test.is_true(has(write_actions, "fs.get"))
        test.is_true(has(write_actions, "fs.read"))
        test.is_true(has(write_actions, "fs.write"))
    end)
    test.it("proves ordinary caller cannot directly read login file or bypass materializer enforcement", function()
        local ws = fresh("ws")
        admit_sources(ws)
        write_file(CODEX_LOGIN_SOURCE, "auth.json", CODEX_FILE_SENTINEL)
        write_file(CLAUDE_LOGIN_SOURCE, ".credentials.json", CLAUDE_FILE_SENTINEL)

        value(call(manager, "define", {workspace_id = ws, name = "codex_login", provider = "codex", source = {kind = "fs_directory", ref = CODEX_LOGIN_SOURCE}}))
        local attempt = fresh("attempt")
        local proj = issue(user, ws, "codex_login", attempt)
        local proj_id = proj.projection_id

        -- 1. Outsider cannot check or materialize
        test.eq(code(call(outsider, "check", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = attempt})), "DENIED")
        test.eq(code(call(outsider, "materialize", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = fresh("k")})), "DENIED")

        -- 2. Workspace manager cannot check or materialize
        test.eq(code(call(manager, "check", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = attempt})), "DENIED")
        test.eq(code(call(manager, "materialize", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = fresh("k")})), "DENIED")

        -- 3. Authenticated subject (user who requested the projection) cannot check or materialize directly
        test.eq(code(call(user, "check", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = attempt})), "DENIED")
        test.eq(code(call(user, "materialize", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = fresh("k")})), "DENIED")

        -- 4. Foreign user cannot check or materialize
        test.eq(code(call(other, "check", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = attempt})), "DENIED")
        test.eq(code(call(other, "materialize", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = fresh("k")})), "DENIED")

        -- Calls reach the probe; the filesystem check itself must deny access.
        -- The positive control proves the same file and probe can read it.
        local admitted = caller(USER, {"bee.tests.credentials:fs_test_policy"})
        local positive, positive_error = bound(admitted, ws):call("bee.tests.credentials:probe_direct_fs_read", CODEX_LOGIN_SOURCE)
        if positive_error or type(positive) ~= "table" then error("direct read control did not execute") end
        test.is_true(positive.ok)
        test.eq(positive.value, CODEX_FILE_SENTINEL)
        for _, ordinary in ipairs({user, manager, outsider}) do
            local denied, denied_error = bound(ordinary, ws):call("bee.tests.credentials:probe_direct_fs_read", CODEX_LOGIN_SOURCE)
            if denied_error or type(denied) ~= "table" then error("direct read probe did not execute") end
            test.is_false(denied.ok)
            test.eq(denied.stage, "get")
            test.is_nil(denied.value)
        end

        -- 6. Admitted runner cannot bypass subject/audience/attempt bounds to read another projection
        test.eq(code(call(runner, "materialize", {projection_id = proj_id, subject = OTHER, audience = USER, attempt_id = attempt, generation_key = fresh("k")})), "DENIED")
        test.eq(code(call(runner, "materialize", {projection_id = proj_id, subject = USER, audience = OTHER, attempt_id = attempt, generation_key = fresh("k")})), "DENIED")
        test.eq(code(call(runner, "materialize", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = fresh("wrong-attempt"), generation_key = fresh("k")})), "DENIED")
    end)
end
return M
