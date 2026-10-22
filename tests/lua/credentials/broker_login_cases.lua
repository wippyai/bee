-- MIT. Focused broker test cases.
local test = require("test")
local bounds = require("bounds")
local principals = require("principals")
local registry = require("registry")
local fs = require("fs")
local support = require("support")
local OTHER = support.OTHER
local USER = support.USER
local SOURCE = support.SOURCE
local CODEX_LOGIN_SOURCE = support.CODEX_LOGIN_SOURCE
local CLAUDE_LOGIN_SOURCE = support.CLAUDE_LOGIN_SOURCE
local MISSING_LOGIN_SOURCE = support.MISSING_LOGIN_SOURCE
local UNPRIVILEGED_LOGIN_SOURCE = support.UNPRIVILEGED_LOGIN_SOURCE
local AGY_ONBOARDING = support.AGY_ONBOARDING
local ONBOARDING_SENTINEL = support.ONBOARDING_SENTINEL
local CODEX_FILE_SENTINEL = support.CODEX_FILE_SENTINEL
local CLAUDE_FILE_SENTINEL = support.CLAUDE_FILE_SENTINEL
local DIGEST = support.DIGEST
local fresh = support.fresh
local manager = support.manager
local user = support.user
local runner = support.runner
local outsider = support.outsider
local call = support.call
local async_call = support.async_call
local await_call = support.await_call
local value = support.value
local code = support.code
local clean = support.clean
local write_file = support.write_file
local fixture_file = support.fixture_file
local admit_sources = support.admit_sources
local issue = support.issue
local M = {}
function M.define(workspace: string)
    test.it("defines file credentials only from host-admitted sources with provider-fixed destinations", function()
        local ws = fresh("ws")
        admit_sources(ws)
        test.eq(code(call(outsider, "define", {workspace_id = ws, name = "codex_login", provider = "codex", source = {kind = "fs_directory", ref = CODEX_LOGIN_SOURCE}})), "DENIED")
        test.eq(code(call(manager, "define", {workspace_id = ws, name = "codex_login", provider = "claude", source = {kind = "fs_directory", ref = CODEX_LOGIN_SOURCE}})), "FORBIDDEN")
        test.eq(code(call(manager, "define", {workspace_id = fresh("ws"), name = "codex_login", provider = "codex", source = {kind = "fs_directory", ref = CODEX_LOGIN_SOURCE}})), "FORBIDDEN")
        test.eq(code(call(manager, "define", {workspace_id = ws, name = "codex_login", provider = "codex", source = {kind = "invalid_kind", ref = CODEX_LOGIN_SOURCE}})), "INVALID")
        test.eq(code(call(manager, "define", {workspace_id = ws, name = "codex_login", provider = "codex", source = {kind = "fs_directory", ref = CODEX_LOGIN_SOURCE}, projection_kind = "environment"})), "INVALID")
        test.eq(code(call(manager, "define", {workspace_id = ws, name = "codex_login", provider = "codex", source = {kind = "fs_directory", ref = CODEX_LOGIN_SOURCE}, destination = "/etc/passwd"})), "INVALID")
        local codex_def = value(call(manager, "define", {workspace_id = ws, name = "codex_login", provider = "codex", source = {kind = "fs_directory", ref = CODEX_LOGIN_SOURCE}}))
        test.eq(codex_def.destination, "auth.json")
        test.eq(codex_def.projection_kind, "file")
        test.eq(codex_def.provider, "codex")
        test.eq(codex_def.revision, 1)
        test.eq(codex_def.optional, false)
        clean(call(manager, "define", {workspace_id = ws, name = "codex_login", provider = "codex", source = {kind = "fs_directory", ref = CODEX_LOGIN_SOURCE}}))
        local claude_def = value(call(manager, "define", {workspace_id = ws, name = "claude_login", provider = "claude", source = {kind = "fs_directory", ref = CLAUDE_LOGIN_SOURCE}}))
        test.eq(claude_def.destination, ".credentials.json")
        test.eq(claude_def.projection_kind, "file")
        test.eq(claude_def.provider, "claude")
        test.eq(claude_def.revision, 1)
        local listed = value(call(manager, "list", {workspace_id = ws}))
        test.eq(#(principals.items(listed.definitions)), 2)
        clean(call(manager, "list", {workspace_id = ws}))
    end)
    test.it("reports provider-fixed login availability by stat without exposing bytes", function()
        local ws = fresh("availability-ws")
        admit_sources(ws)
        write_file(CODEX_LOGIN_SOURCE, "auth.json", CODEX_FILE_SENTINEL)

        local present_def = value(call(manager, "define", {workspace_id = ws, name = "present_login", provider = "codex", source = {kind = "fs_directory", ref = CODEX_LOGIN_SOURCE}}))
        local missing_def = value(call(manager, "define", {workspace_id = ws, name = "missing_login", provider = "codex", source = {kind = "fs_directory", ref = MISSING_LOGIN_SOURCE}}))
        value(call(manager, "define", {workspace_id = ws, name = "denied_login", provider = "codex", source = {kind = "fs_directory", ref = UNPRIVILEGED_LOGIN_SOURCE}}))
        write_file(UNPRIVILEGED_LOGIN_SOURCE, "auth.json", CODEX_FILE_SENTINEL)

        local present = value(call(manager, "availability", {workspace_id = ws, name = "present_login"}))
        test.eq(present.present, true)
        test.eq(present.optional, false)
        test.eq(present.definition_id, present_def.definition_id)
        test.eq(present.revision, 1)
        test.eq(present.destination, "auth.json")
        clean(call(manager, "availability", {workspace_id = ws, name = "present_login"}))

        local missing = value(call(manager, "availability", {workspace_id = ws, name = "missing_login"}))
        test.eq(missing.present, false)
        test.eq(missing.optional, false)
        test.eq(missing.definition_id, missing_def.definition_id)
        test.eq(missing.destination, "auth.json")
        clean(call(manager, "availability", {workspace_id = ws, name = "missing_login"}))

        -- The source allowlist admits this root, but the host file policy
        -- deliberately omits it. The probe must fail closed.
        test.eq(code(call(manager, "availability", {workspace_id = ws, name = "denied_login"})), "UNAVAILABLE")
        test.eq(code(call(outsider, "availability", {workspace_id = ws, name = "present_login"})), "DENIED")

        local env_def = value(call(manager, "define", {workspace_id = ws, name = "environment", provider = "claude", source = {kind = "env_variable", ref = SOURCE}}))
        test.eq(env_def.projection_kind, "environment")
        test.eq(code(call(manager, "availability", {workspace_id = ws, name = "environment"})), "INVALID")

        local source_entry = registry.get("bee.credentials.env:credential_sources")
        if not source_entry then error("sources entry") end
        local source_data = assert(bounds.object(source_entry.data))
        local saved_sources = source_data.sources
        source_data.sources = {}
        local changes = registry.snapshot():changes()
        changes:update(source_entry)
        local applied, apply_error = changes:apply()
        if not applied then error("remove availability source: " .. tostring(apply_error)) end
        test.eq(code(call(manager, "availability", {workspace_id = ws, name = "present_login"})), "FORBIDDEN")
        source_data.sources = saved_sources
        local restore = registry.snapshot():changes()
        restore:update(source_entry)
        local restored, restore_error = restore:apply()
        if not restored then error("restore availability source: " .. tostring(restore_error)) end
    end)
    test.it("pins a host-selected nested login path and refuses source retargeting", function()
        local ws = fresh("nested-login")
        admit_sources(ws)
        local function select_path(path: string)
            local entry = registry.get("bee.credentials.env:credential_sources")
            if not entry then error("sources") end
            for _, source in ipairs(principals.objects(entry.data.sources)) do
                if source.ref == CODEX_LOGIN_SOURCE then source.path = path end
            end
            local changes = registry.snapshot():changes()
            changes:update(entry)
            local applied, err = changes:apply()
            if not applied then error(tostring(err)) end
        end
        select_path(".codex/auth.json")
        local volume = fs.get(CODEX_LOGIN_SOURCE)
        if not volume then error("fixture volume") end
        if not volume:exists(".codex") then
            local made, err = volume:mkdir(".codex")
            if not made then error(tostring(err)) end
        end
        write_file(CODEX_LOGIN_SOURCE, ".codex/auth.json", CODEX_FILE_SENTINEL)
        value(call(manager, "define", {workspace_id = ws, name = "login", provider = "codex",
            source = {kind = "fs_directory", ref = CODEX_LOGIN_SOURCE}, optional = true}))
        test.eq(value(call(manager, "availability", {workspace_id = ws, name = "login"})).present, true)
        local attempt = fresh("attempt")
        local projection = issue(user, ws, "login", attempt)
        local request = {projection_id = projection.projection_id, subject = USER, audience = USER, attempt_id = attempt}
        test.eq(value(call(runner, "check", request)).destination, "auth.json")
        select_path("different/auth.json")
        test.eq(code(call(manager, "availability", {workspace_id = ws, name = "login"})), "CONFLICT")
        test.eq(code(call(runner, "check", request)), "CONFLICT")
        select_path(".codex/auth.json")
        test.eq(value(call(manager, "availability", {workspace_id = ws, name = "login"})).present, true)
        test.eq(value(call(runner, "check", request)).destination, "auth.json")
        -- A changed host-selected format is fenced independently of the
        -- source digest and cannot retarget a retained projection.
        local format_entry = registry.get("bee.drivers.codex.credentials:credential_format")
        if not format_entry then error("codex credential format") end
        local format_data = assert(bounds.object(format_entry.data))
        local file_data = assert(bounds.object(format_data.file))
        local saved_format_path = file_data.path
        -- Keep the basename and source unchanged: only the destination
        -- directory changes, so destination-name checks cannot prove this.
        file_data.path = ".moved/auth.json"
        local format_changes = registry.snapshot():changes()
        format_changes:update(format_entry)
        local format_applied, format_apply_error = format_changes:apply()
        if not format_applied then error(tostring(format_apply_error)) end
        local format_ok, format_failure = pcall(function()
            test.eq(code(call(manager, "availability", {workspace_id = ws, name = "login"})), "CONFLICT")
            test.eq(code(call(runner, "check", request)), "CONFLICT")
            test.eq(code(call(runner, "materialize", {projection_id = projection.projection_id, subject = USER, audience = USER,
                attempt_id = attempt, generation_key = fresh("format-generation")})), "CONFLICT")
        end)
        file_data.path = saved_format_path
        local format_restore = registry.snapshot():changes()
        format_restore:update(format_entry)
        local format_restored, format_restore_error = format_restore:apply()
        if not format_restored then error(tostring(format_restore_error)) end
        if not format_ok then error(tostring(format_failure)) end
        select_path("different/auth.json")
        local rejected = call(runner, "materialize", {projection_id = projection.projection_id, subject = USER, audience = USER,
            attempt_id = attempt, generation_key = fresh("generation")})
        test.eq(code(rejected), "CONFLICT")
        clean(rejected)
        select_path(".codex/auth.json")
        local materialized = value(call(runner, "materialize", {projection_id = projection.projection_id, subject = USER, audience = USER,
            attempt_id = attempt, generation_key = fresh("generation")}))
        test.eq(materialized.value, CODEX_FILE_SENTINEL)
        test.eq(materialized.destination, "auth.json")
        select_path("../escape")
        test.eq(code(call(manager, "availability", {workspace_id = ws, name = "login"})), "STORAGE")
        admit_sources(ws)
    end)
    test.it("issues file projections and materializes bytes once to admitted materializer only", function()
        local ws = fresh("ws")
        admit_sources(ws)
        write_file(CODEX_LOGIN_SOURCE, "auth.json", CODEX_FILE_SENTINEL)
        write_file(CLAUDE_LOGIN_SOURCE, ".credentials.json", CLAUDE_FILE_SENTINEL)

        value(call(manager, "define", {workspace_id = ws, name = "codex_login", provider = "codex", source = {kind = "fs_directory", ref = CODEX_LOGIN_SOURCE}}))
        value(call(manager, "define", {workspace_id = ws, name = "claude_login", provider = "claude", source = {kind = "fs_directory", ref = CLAUDE_LOGIN_SOURCE}}))

        local attempt = fresh("attempt")
        test.eq(code(call(outsider, "issue_projection", {workspace_id = ws, name = "codex_login", audience = USER, attempt_id = attempt, profile_id = "batch", profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = fresh("key")})), "DENIED")
        local proj = issue(user, ws, "codex_login", attempt)
        test.eq(proj.subject, USER)
        test.eq(proj.destination, "auth.json")
        test.eq(proj.projection_kind, "file")
        test.eq(proj.materializer, "bee.placement.native.binding:binding")
        test.eq(proj.materialization_generation, 0)
        clean(call(user, "issue_projection", {workspace_id = ws, name = "codex_login", audience = USER, attempt_id = attempt, profile_id = "batch", profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = fresh("key")}))

        local proj_id = proj.projection_id
        test.eq(code(call(user, "check", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = attempt})), "DENIED")
        local checked = value(call(runner, "check", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = attempt}))
        test.eq(checked.projection_id, proj_id)
        test.eq(checked.projection_kind, "file")
        test.eq(checked.destination, "auth.json")
        test.eq(checked.source_present, true)
        clean(call(runner, "check", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = attempt}))

        test.eq(code(call(user, "materialize", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "fg1"})), "DENIED")
        test.eq(code(call(runner, "materialize", {projection_id = proj_id, subject = OTHER, audience = USER, attempt_id = attempt, generation_key = "fg1"})), "DENIED")
        test.eq(code(call(runner, "materialize", {projection_id = proj_id, subject = USER, audience = OTHER, attempt_id = attempt, generation_key = "fg1"})), "DENIED")
        test.eq(code(call(runner, "materialize", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = "attempt-other", generation_key = "fg1"})), "DENIED")

        local mat = value(call(runner, "materialize", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "fg1"}))
        test.eq(mat.value, CODEX_FILE_SENTINEL)
        test.eq(mat.destination, "auth.json")
        test.eq(mat.projection_kind, "file")
        test.eq(mat.encoding, "utf-8")
        test.eq(mat.generation, 1)
        test.eq(mat.present, true)
        test.eq(mat.optional, false)

        test.eq(code(call(runner, "materialize", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "fg1"})), "CONFLICT")

        local mat2 = value(call(runner, "materialize", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "fg2"}))
        test.eq(mat2.generation, 2)
        test.eq(mat2.value, CODEX_FILE_SENTINEL)
        test.eq(mat2.present, true)
        test.eq(mat2.optional, false)

        local after = value(call(runner, "check", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = attempt}))
        test.eq(after.materialization_generation, 2)
        clean(call(runner, "check", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = attempt}))

        -- Agy selects an opaque host format. Arbitrary bytes pass through
        -- without JSON parsing and are labeled as bytes for placement.
        write_file(CODEX_LOGIN_SOURCE, "antigravity-oauth-token", "opaque-login-bytes")
        write_file(CODEX_LOGIN_SOURCE, AGY_ONBOARDING, '{"consumerOnboardingComplete":"' .. ONBOARDING_SENTINEL .. '"}')
        local agy_def = value(call(manager, "define", {workspace_id = ws, name = "agy_login", provider = "agy",
            source = {kind = "fs_directory", ref = CODEX_LOGIN_SOURCE}}))
        test.eq(agy_def.destination, "antigravity-oauth-token")
        local agy_proj = issue(user, ws, "agy_login", attempt)
        local agy_mat = value(call(runner, "materialize", {projection_id = agy_proj.projection_id, subject = USER,
            audience = USER, attempt_id = attempt, generation_key = "agy-g1"}))
        test.eq(agy_mat.value, "opaque-login-bytes")
        test.eq(agy_mat.encoding, "bytes")
        test.eq(agy_mat.destination, "antigravity-oauth-token")
        test.eq(agy_mat.format.file.content_format, "opaque")
        test.eq(agy_mat.format.file.initialize[1].path, AGY_ONBOARDING)
        test.eq(agy_mat.format.file.initialize[1].content, '{"consumerOnboardingComplete":"' .. ONBOARDING_SENTINEL .. '"}')

        local claude_proj = issue(user, ws, "claude_login", attempt)
        test.eq(claude_proj.destination, ".credentials.json")
        test.eq(claude_proj.projection_kind, "file")
        local claude_mat = value(call(runner, "materialize", {projection_id = claude_proj.projection_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "cg1"}))
        test.eq(claude_mat.destination, ".credentials.json")
        test.eq(claude_mat.projection_kind, "file")
        test.eq(claude_mat.value, CLAUDE_FILE_SENTINEL)
    end)
    test.it("writes refreshed tokens only to the exact admitted login file while the original digest still matches", function()
        local ws = fresh("token-writeback")
        admit_sources(ws)
        local original = '{"access_token":"fixture-original","auth_mode":"chatgpt"}'
        local refreshed = '{"access_token":"fixture-refreshed","auth_mode":"chatgpt"}'
        local newer_login = '{"access_token":"fixture-newer-machine-login","auth_mode":"chatgpt"}'
        write_file(CODEX_LOGIN_SOURCE, "auth.json", original)
        value(call(manager, "define", {workspace_id = ws, name = "codex_login", provider = "codex",
            source = {kind = "fs_directory", ref = CODEX_LOGIN_SOURCE}}))
        local attempt = fresh("writeback-attempt")
        local projection = issue(user, ws, "codex_login", attempt)
        local materialized = value(call(runner, "materialize", {projection_id = projection.projection_id,
            subject = USER, audience = USER, attempt_id = attempt, generation_key = "writeback-generation"}))
        test.eq(type(materialized.source_digest), "string")
        test.eq(#(materialized.source_digest), 64)
        test.eq(code(call(runner, "write_back", {projection_id = projection.projection_id, subject = USER, audience = USER,
            attempt_id = attempt, generation = materialized.generation, source_digest = materialized.source_digest, value = refreshed, path = "other.json"})), "INVALID")
        test.eq(code(call(runner, "write_back", {projection_id = projection.projection_id, subject = USER, audience = USER,
            attempt_id = attempt, generation = assert(bounds.integer(materialized.generation)) + 1, source_digest = materialized.source_digest, value = refreshed})), "DENIED")
        local update = call(runner, "write_back", {projection_id = projection.projection_id, subject = USER, audience = USER,
            attempt_id = attempt, generation = materialized.generation, source_digest = materialized.source_digest, value = refreshed})
        clean(update)
        test.eq(value(update).written, true)
        test.is_true(fixture_file(CODEX_LOGIN_SOURCE, "auth.json") == refreshed)
        write_file(CODEX_LOGIN_SOURCE, "auth.json", newer_login)
        local stale = call(runner, "write_back", {projection_id = projection.projection_id, subject = USER, audience = USER,
            attempt_id = attempt, generation = materialized.generation, source_digest = materialized.source_digest, value = refreshed})
        test.eq(code(stale), "CONFLICT")
        clean(stale)
        test.is_true(fixture_file(CODEX_LOGIN_SOURCE, "auth.json") == newer_login)
    end)
    test.it("serializes refreshes from two projections of the same login source", function()
        local ws = fresh("token-writeback-race")
        admit_sources(ws)
        local original = '{"access_token":"fixture-race-original","auth_mode":"chatgpt"}'
        local first_refresh = '{"access_token":"fixture-race-first","auth_mode":"chatgpt"}'
        local second_refresh = '{"access_token":"fixture-race-second","auth_mode":"chatgpt"}'
        write_file(CODEX_LOGIN_SOURCE, "auth.json", original)
        value(call(manager, "define", {workspace_id = ws, name = "codex_login", provider = "codex",
            source = {kind = "fs_directory", ref = CODEX_LOGIN_SOURCE}}))
        local first_attempt, second_attempt = fresh("race-attempt"), fresh("race-attempt")
        local first_projection = issue(user, ws, "codex_login", first_attempt)
        local second_projection = issue(user, ws, "codex_login", second_attempt)
        local first = value(call(runner, "materialize", {projection_id = first_projection.projection_id,
            subject = USER, audience = USER, attempt_id = first_attempt, generation_key = "race-first-generation"}))
        local second = value(call(runner, "materialize", {projection_id = second_projection.projection_id,
            subject = USER, audience = USER, attempt_id = second_attempt, generation_key = "race-second-generation"}))
        test.eq(first.source_digest, second.source_digest)
        local first_future = async_call(runner, "write_back", {projection_id = first_projection.projection_id,
            subject = USER, audience = USER, attempt_id = first_attempt, generation = first.generation,
            source_digest = first.source_digest, value = first_refresh})
        local second_future = async_call(runner, "write_back", {projection_id = second_projection.projection_id,
            subject = USER, audience = USER, attempt_id = second_attempt, generation = second.generation,
            source_digest = second.source_digest, value = second_refresh})
        local first_result, second_result = await_call(first_future), await_call(second_future)
        local successes = (first_result.ok and 1 or 0) + (second_result.ok and 1 or 0)
        test.eq(successes, 1)
        local refused = first_result.ok and second_result or first_result
        test.eq(code(refused), "CONFLICT")
        local stored = fixture_file(CODEX_LOGIN_SOURCE, "auth.json")
        test.is_true(stored == first_refresh or stored == second_refresh)
    end)
    test.it("projects one requested Codex profile file and refuses paths outside host admission", function()
        local ws = fresh("codex-profile-file")
        admit_sources(ws)
        local profile_path = ".codex/fixture-profile.config.toml"
        local profile_content = 'model = "gpt-5-codex"\n'
        write_file(CODEX_LOGIN_SOURCE, "auth.json", CODEX_FILE_SENTINEL)
        write_file(CODEX_LOGIN_SOURCE, ".codex/config.toml", "profile = \"base\"\n")
        write_file(CODEX_LOGIN_SOURCE, profile_path, profile_content)
        value(call(manager, "define", {workspace_id = ws, name = "codex_profile_login", provider = "codex",
            source = {kind = "fs_directory", ref = CODEX_LOGIN_SOURCE}}))
        local attempt = fresh("codex-profile-attempt")
        local projection = issue(user, ws, "codex_profile_login", attempt)
        test.eq(code(call(runner, "materialize", {projection_id = projection.projection_id, subject = USER, audience = USER,
            attempt_id = attempt, generation_key = "codex-profile-denied", provider_files = {{source_path = ".codex/secrets.json", path = ".codex/secrets.json", optional = false}}})), "FORBIDDEN")
        test.eq(code(call(runner, "materialize", {projection_id = projection.projection_id, subject = USER, audience = USER,
            attempt_id = attempt, generation_key = "codex-baseline-duplicate", provider_files = {{source_path = ".codex/config.toml", path = ".codex/.bee-user-config.toml", optional = true}}})), "CONFLICT")
        local materialized = value(call(runner, "materialize", {projection_id = projection.projection_id, subject = USER, audience = USER,
            attempt_id = attempt, generation_key = "codex-profile-present", provider_files = {{source_path = profile_path, path = profile_path, optional = false}}}))
        local found = false
        for _, item in ipairs((principals.objects(materialized.format.file.initialize))) do
            if item.path == profile_path then
                test.eq(item.source_path, profile_path)
                test.eq(item.content, profile_content)
                found = true
            end
        end
        test.is_true(found)
        local missing_profile = ".codex/not-installed.config.toml"
        local optional_attempt = fresh("codex-optional-profile-attempt")
        local optional_projection = issue(user, ws, "codex_profile_login", optional_attempt)
        local optional_materialization = value(call(runner, "materialize", {projection_id = optional_projection.projection_id,
            subject = USER, audience = USER, attempt_id = optional_attempt, generation_key = "codex-profile-optional-missing",
            provider_files = {{source_path = missing_profile, path = missing_profile, optional = true}}}))
        for _, item in ipairs((principals.objects(optional_materialization.format.file.initialize))) do
            test.is_false(item.path == missing_profile)
        end
    end)
    test.it("refuses token write-back unless the host source explicitly admits it", function()
        local ws = fresh("token-writeback-not-admitted")
        admit_sources(ws)
        write_file(CODEX_LOGIN_SOURCE, "auth.json", CODEX_FILE_SENTINEL)
        local entry = registry.get("bee.credentials.env:credential_sources")
        if not entry then error("credential sources entry") end
        for _, item in ipairs(principals.objects((assert(bounds.object(entry.data))).sources)) do
            if item.ref == CODEX_LOGIN_SOURCE and item.provider == "codex" and item.audience == USER then item.write_back = false end
        end
        local changed = registry.snapshot():changes()
        changed:update(entry)
        local applied, apply_error = changed:apply()
        if not applied then error("disable token write-back: " .. tostring(apply_error)) end
        local ws_reply = call(manager, "define", {workspace_id = ws, name = "codex_read_only_login", provider = "codex",
            source = {kind = "fs_directory", ref = CODEX_LOGIN_SOURCE}})
        clean(ws_reply)
        local ws_definition = value(ws_reply)
        local attempt = fresh("read-only-login-attempt")
        local projection = issue(user, ws, "codex_read_only_login", attempt)
        local materialized = value(call(runner, "materialize", {projection_id = projection.projection_id, subject = USER, audience = USER,
            attempt_id = attempt, generation_key = "read-only-login-generation"}))
        test.eq(materialized.write_back, false)
        test.eq(code(call(runner, "write_back", {projection_id = projection.projection_id, subject = USER, audience = USER,
            attempt_id = attempt, generation = materialized.generation, source_digest = string.rep("0", 64), value = CODEX_FILE_SENTINEL})), "DENIED")
    end)
end
return M
