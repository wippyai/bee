-- MIT. The credential broker with a sentinel secret: definitions stay under
-- the host allowlist, projections bind exactly, only an admitted
-- materializer receives bytes, and the sentinel never appears anywhere but
-- in that one reply.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local time = require("time")
local json = require("json")
local fs = require("fs")
local broker = require("broker")
local persist = require("persist")
local migrations = require("migrations")
local cred_sources = require("cred_sources")
local SENTINEL = "sentinel-secret-7f3a9c"
local SOURCE = "bee.credentials:sentinel_key"
local OTHER_SOURCE = "bee.credentials:other_key"
local BROKEN_SOURCE = "bee.credentials:broken_key"
local CODEX_LOGIN_SOURCE = "bee.credentials:codex_login_fixture"
local CLAUDE_LOGIN_SOURCE = "bee.credentials:claude_login_fixture"
local INVALID_LOGIN_SOURCE = "bee.credentials:invalid_login_fixture"
local MISSING_LOGIN_SOURCE = "bee.credentials:missing_login_fixture"
local UNPRIVILEGED_LOGIN_SOURCE = "bee.credentials:unprivileged_login_fixture"
local CODEX_FILE_SENTINEL = '{"access_token":"sentinel-codex-tok-123","auth_mode":"chatgpt"}'
local CLAUDE_FILE_SENTINEL = '{"sessionKey":"sentinel-claude-key-456"}'
local MANAGER, USER, OTHER, RUNNER = "bee.test.cred.manager", "bee.test.cred.user", "bee.test.cred.other", "bee.test.cred.runner"
local DIGEST = string.rep("c", 64)
local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end
local function scope(names: {string}): security.Scope
    local policies: {security.Policy} = {}
    for index, name in ipairs(names) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    return security.new_scope(policies)
end
local function caller(id: string, grants: {string}): funcs.Executor
    local names: {string} = {"bee.credentials:client_test_policy"}
    for _, grant in ipairs(grants) do names[#names + 1] = grant end
    return funcs.new():with_actor(security.new_actor(id)):with_scope(scope(names))
end
local manager = caller(MANAGER, {"bee:credential_manage_policy"})
local user = caller(USER, {"bee:credential_issue_policy"})
local other = caller(OTHER, {"bee:credential_issue_policy"})
local runner = caller(RUNNER, {"bee:credential_materialize_policy"})
local outsider = caller("bee.test.cred.outsider", {})
local function call(client: funcs.Executor, method: string, value: unknown): broker.Reply
    local reply, err = client:call("bee.credentials:" .. method, value)
    if err then error(method .. ": " .. tostring(err)) end
    return reply :: broker.Reply
end
local function value(reply: broker.Reply): {[string]: unknown}
    if not reply.ok then error(tostring(reply.error and reply.error.code) .. ": " .. tostring(reply.error and reply.error.message)) end
    return reply.value :: {[string]: unknown}
end
local function code(reply: broker.Reply): string
    if reply.ok then error("expected a failure, got success") end
    return reply.error and reply.error.code or ""
end
local function clean(reply: broker.Reply)
    local encoded = tostring(json.encode(reply))
    if encoded:find(SENTINEL, 1, true) then error("sentinel leaked into a reply that must not carry it") end
    if encoded:find("sentinel-codex-tok-123", 1, true) then error("codex login sentinel leaked into a reply that must not carry it") end
    if encoded:find("sentinel-claude-key-456", 1, true) then error("claude login sentinel leaked into a reply that must not carry it") end
    if encoded:find("chatgpt", 1, true) then error("codex login auth_mode leaked into a reply that must not carry it") end
    if encoded:find("sessionKey", 1, true) then error("claude login sessionKey leaked into a reply that must not carry it") end
end
local function write_file(ref: string, path: string, content: string)
    local volume, err = fs.get(ref)
    if not volume then error("volume " .. ref .. ": " .. tostring(err)) end
    local ok, werr = volume:writefile(path, content)
    if not ok then error("writefile " .. path .. ": " .. tostring(werr)) end
end
local function admit_sources(workspace: string)
    local entry = registry.get("bee:credential_sources")
    if not entry then error("credential sources entry") end
    local data = entry.data :: {[string]: unknown}
    data.sources = {{ref = SOURCE, workspace_id = "*", audience = USER, provider = "claude", projection_kinds = {"environment"}},
        {ref = OTHER_SOURCE, workspace_id = workspace, audience = "*", provider = "codex", projection_kinds = {"environment"}},
        {ref = BROKEN_SOURCE, workspace_id = workspace, audience = "*", provider = "codex", projection_kinds = {"environment"}},
        {ref = CODEX_LOGIN_SOURCE, workspace_id = workspace, audience = USER, provider = "codex", projection_kinds = {"file"}},
        {ref = CLAUDE_LOGIN_SOURCE, workspace_id = "*", audience = USER, provider = "claude", projection_kinds = {"file"}},
        {ref = INVALID_LOGIN_SOURCE, workspace_id = workspace, audience = USER, provider = "codex", projection_kinds = {"file"}},
        {ref = MISSING_LOGIN_SOURCE, workspace_id = workspace, audience = USER, provider = "codex", projection_kinds = {"file"}},
        {ref = UNPRIVILEGED_LOGIN_SOURCE, workspace_id = workspace, audience = USER, provider = "codex", projection_kinds = {"file"}}}
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local file_policy = registry.get("bee:credential_file_policy")
    if not file_policy then error("credential file policy entry") end
    file_policy.data.policy.resources = {CODEX_LOGIN_SOURCE, CLAUDE_LOGIN_SOURCE, INVALID_LOGIN_SOURCE, MISSING_LOGIN_SOURCE}
    changes:update(file_policy)
    local applied, err = changes:apply()
    if not applied then error("admit sources: " .. tostring(err)) end
end
local function issue(client: funcs.Executor, workspace: string, name: string, attempt: string, extra: {[string]: unknown}?): {[string]: unknown}
    local request: {[string]: unknown} = {workspace_id = workspace, name = name, audience = USER, attempt_id = attempt, profile_id = "batch", profile_digest = DIGEST,
        binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = fresh("key")}
    for key, item in pairs(extra or {}) do request[key] = item end
    return value(call(client, "issue_projection", request))
end
local function define_tests()
    test.describe("Credential broker", function()
        local workspace = fresh("ws")
        admit_sources(workspace)
        test.it("defines credentials only from host-admitted sources, for managers, with digests that carry no bytes", function()
            test.eq(code(call(outsider, "define", {workspace_id = workspace, name = "anthropic", provider = "claude", source = {kind = "env_variable", ref = SOURCE}})), "DENIED")
            test.eq(code(call(manager, "define", {workspace_id = workspace, name = "anthropic", provider = "codex", source = {kind = "env_variable", ref = SOURCE}})), "FORBIDDEN")
            test.eq(code(call(manager, "define", {workspace_id = fresh("ws"), name = "openai", provider = "codex", source = {kind = "env_variable", ref = OTHER_SOURCE}})), "FORBIDDEN")
            test.eq(code(call(manager, "define", {workspace_id = workspace, name = "anthropic", provider = "claude", source = {kind = "env_file_key", ref = SOURCE}})), "INVALID")
            local defined = value(call(manager, "define", {workspace_id = workspace, name = "anthropic", provider = "claude", source = {kind = "env_variable", ref = SOURCE}}))
            test.eq(defined.destination, "ANTHROPIC_API_KEY")
            test.eq(defined.revision, 1)
            test.is_nil(tostring(json.encode(defined)):find(SENTINEL, 1, true))
            local openai = value(call(manager, "define", {workspace_id = workspace, name = "openai", provider = "codex", source = {kind = "env_variable", ref = OTHER_SOURCE}}))
            test.eq(openai.destination, "OPENAI_API_KEY")
            local listed = value(call(manager, "list", {workspace_id = workspace}))
            test.eq(#(listed.definitions :: {unknown}), 2)
            clean(call(manager, "list", {workspace_id = workspace}))
        end)
        test.it("first-use credential creation and stale updates preserve the existing definition and projection", function()
            local name = fresh("login")
            local request = {workspace_id = workspace, name = name, provider = "claude", source = {kind = "env_variable", ref = SOURCE}, expected_revision = 0}
            local created = value(call(manager, "define", request))
            test.eq(created.revision, 1)
            local attempt = fresh("attempt")
            local projection = issue(user, workspace, name, attempt)
            test.eq(code(call(manager, "define", request)), "CONFLICT")
            local checked = value(call(runner, "check", {projection_id = projection.projection_id, subject = USER, audience = USER, attempt_id = attempt}))
            test.eq(checked.projection_id, projection.projection_id)
            request.expected_revision = 1
            local replaced = value(call(manager, "define", request))
            test.eq(replaced.revision, 2)
            test.eq(code(call(manager, "define", request)), "CONFLICT")
            request.expected_revision = -1
            test.eq(code(call(manager, "define", request)), "INVALID")
            request.expected_revision = 0.5
            test.eq(code(call(manager, "define", request)), "INVALID")
        end)
        test.it("issues projections to the authenticated subject and materializes bytes once for the admitted materializer only", function()
            local attempt = fresh("attempt")
            test.eq(code(call(outsider, "issue_projection", {workspace_id = workspace, name = "anthropic", audience = USER, attempt_id = attempt, profile_id = "batch", profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = fresh("key")})), "DENIED")
            local projection = issue(user, workspace, "anthropic", attempt)
            test.eq(projection.subject, USER)
            test.eq(projection.destination, "ANTHROPIC_API_KEY")
            test.eq(projection.materializer, "bee.placement.native:binding")
            test.eq(projection.materialization_generation, 0)
            clean(call(user, "issue_projection", {workspace_id = workspace, name = "anthropic", audience = USER, attempt_id = attempt, profile_id = "batch", profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = fresh("key")}))
            local id = projection.projection_id :: string
            test.eq(code(call(user, "check", {projection_id = id, subject = USER, audience = USER, attempt_id = attempt})), "DENIED")
            test.eq(code(call(user, "materialize", {projection_id = id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "g1"})), "DENIED")
            local checked = value(call(runner, "check", {projection_id = id, subject = USER, audience = USER, attempt_id = attempt}))
            test.eq(checked.projection_id, id)
            clean(call(runner, "check", {projection_id = id, subject = USER, audience = USER, attempt_id = attempt}))
            test.eq(code(call(runner, "materialize", {projection_id = id, subject = OTHER, audience = USER, attempt_id = attempt, generation_key = "g1"})), "DENIED")
            test.eq(code(call(runner, "materialize", {projection_id = id, subject = USER, audience = OTHER, attempt_id = attempt, generation_key = "g1"})), "DENIED")
            test.eq(code(call(runner, "materialize", {projection_id = id, subject = USER, audience = USER, attempt_id = "attempt-else", generation_key = "g1"})), "DENIED")
            local materialized = value(call(runner, "materialize", {projection_id = id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "g1"}))
            test.eq(materialized.value, SENTINEL)
            test.eq(materialized.destination, "ANTHROPIC_API_KEY")
            test.eq(materialized.encoding, "utf-8")
            test.eq(materialized.generation, 1)
            test.eq(code(call(runner, "materialize", {projection_id = id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "g1"})), "CONFLICT")
            local again = value(call(runner, "materialize", {projection_id = id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "g2"}))
            test.eq(again.generation, 2)
            local after = value(call(runner, "check", {projection_id = id, subject = USER, audience = USER, attempt_id = attempt}))
            test.eq(after.materialization_generation, 2)
            clean(call(runner, "check", {projection_id = id, subject = USER, audience = USER, attempt_id = attempt}))
            clean(call(manager, "list", {workspace_id = workspace}))
            local replay = value(call(user, "issue_projection", {workspace_id = workspace, name = "anthropic", audience = USER, attempt_id = attempt, profile_id = "batch", profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = "replay-" .. attempt}))
            local same = value(call(user, "issue_projection", {workspace_id = workspace, name = "anthropic", audience = USER, attempt_id = attempt, profile_id = "batch", profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = "replay-" .. attempt}))
            test.eq(same.projection_id, replay.projection_id)
            test.eq(code(call(user, "issue_projection", {workspace_id = workspace, name = "anthropic", audience = USER, attempt_id = "attempt-other", profile_id = "batch", profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = "replay-" .. attempt})), "CONFLICT")
        end)
        test.it("refuses values an environment cannot carry without echoing them", function()
            local attempt = fresh("attempt")
            value(call(manager, "define", {workspace_id = workspace, name = "broken", provider = "codex", source = {kind = "env_variable", ref = BROKEN_SOURCE}}))
            local projection = issue(user, workspace, "broken", attempt)
            local refused = call(runner, "materialize", {projection_id = projection.projection_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "g"})
            test.eq(code(refused), "INVALID")
            if tostring(json.encode(refused)):find("secret-9d8e7f", 1, true) then error("broken value leaked into the refusal") end
        end)
        test.it("stops materializing on expiry, revocation, epoch advance and redefinition, and reads the source at each materialization", function()
            local attempt = fresh("attempt")
            local short = issue(user, workspace, "anthropic", attempt, {ttl_ms = 1})
            time.sleep("20ms")
            test.eq(code(call(runner, "materialize", {projection_id = short.projection_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "g"})), "EXPIRED")
            local revocable = issue(user, workspace, "anthropic", attempt)
            test.eq(code(call(other, "revoke", {projection_id = revocable.projection_id})), "DENIED")
            clean(call(user, "revoke", {projection_id = revocable.projection_id}))
            test.eq(code(call(runner, "check", {projection_id = revocable.projection_id, subject = USER, audience = USER, attempt_id = attempt})), "REVOKED")
            local epochal = issue(user, workspace, "anthropic", attempt)
            value(call(runner, "check", {projection_id = epochal.projection_id, subject = USER, audience = USER, attempt_id = attempt}))
            test.eq(code(call(user, "revoke_all", {workspace_id = workspace})), "DENIED")
            value(call(manager, "revoke_all", {workspace_id = workspace}))
            test.eq(code(call(runner, "materialize", {projection_id = epochal.projection_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "g"})), "REVOKED")
            local renewed = issue(user, workspace, "anthropic", attempt)
            test.eq(renewed.authorization_epoch, 1)
            value(call(runner, "check", {projection_id = renewed.projection_id, subject = USER, audience = USER, attempt_id = attempt}))
            local redefined = value(call(manager, "define", {workspace_id = workspace, name = "anthropic", provider = "claude", source = {kind = "env_variable", ref = SOURCE}}))
            test.eq(redefined.revision, 2)
            test.eq(code(call(runner, "check", {projection_id = renewed.projection_id, subject = USER, audience = USER, attempt_id = attempt})), "CONFLICT")
            local foreign_audience = code(call(user, "issue_projection", {workspace_id = workspace, name = "anthropic", audience = OTHER, attempt_id = attempt, profile_id = "batch", profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = fresh("key")}))
            test.eq(foreign_audience, "FORBIDDEN")
            local live = issue(user, workspace, "anthropic", attempt)
            value(call(runner, "check", {projection_id = live.projection_id, subject = USER, audience = USER, attempt_id = attempt}))
            local entry = registry.get("bee:credential_sources")
            if not entry then error("sources entry") end
            local data = entry.data :: {[string]: unknown}
            data.sources = {{ref = OTHER_SOURCE, workspace_id = workspace, audience = "*", provider = "codex", projection_kinds = {"environment"}}}
            local changes = registry.snapshot():changes()
            changes:update(entry)
            local applied, apply_error = changes:apply()
            if not applied then error("remove source: " .. tostring(apply_error)) end
            test.eq(code(call(runner, "materialize", {projection_id = live.projection_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "removed"})), "FORBIDDEN")
            admit_sources(workspace)
            local reported = value(call(outsider, "capabilities", {}))
            test.eq(reported.repeat_generation, "refused")
            test.eq(reported.file_projections, true)
            test.eq(reported.provider_revocation, false)
            test.eq(reported.rotation, "next_materialization")
            test.eq(reported.revocation_enforcement, "stop_on_reconcile")
            test.eq(reported.max_file_bytes, 65536)
            local kinds = reported.projection_kinds :: {string}
            test.eq(kinds[1], "environment")
            test.eq(kinds[2], "file")
            local fdest = reported.file_destinations :: {[string]: string}
            test.eq(fdest.claude, ".credentials.json")
            test.eq(fdest.codex, "auth.json")
        end)
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
            clean(call(manager, "define", {workspace_id = ws, name = "codex_login", provider = "codex", source = {kind = "fs_directory", ref = CODEX_LOGIN_SOURCE}}))
            local claude_def = value(call(manager, "define", {workspace_id = ws, name = "claude_login", provider = "claude", source = {kind = "fs_directory", ref = CLAUDE_LOGIN_SOURCE}}))
            test.eq(claude_def.destination, ".credentials.json")
            test.eq(claude_def.projection_kind, "file")
            test.eq(claude_def.provider, "claude")
            test.eq(claude_def.revision, 1)
            local listed = value(call(manager, "list", {workspace_id = ws}))
            test.eq(#(listed.definitions :: {unknown}), 2)
            clean(call(manager, "list", {workspace_id = ws}))
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
            test.eq(proj.materializer, "bee.placement.native:binding")
            test.eq(proj.materialization_generation, 0)
            clean(call(user, "issue_projection", {workspace_id = ws, name = "codex_login", audience = USER, attempt_id = attempt, profile_id = "batch", profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = fresh("key")}))

            local proj_id = proj.projection_id :: string
            test.eq(code(call(user, "check", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = attempt})), "DENIED")
            local checked = value(call(runner, "check", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = attempt}))
            test.eq(checked.projection_id, proj_id)
            test.eq(checked.projection_kind, "file")
            test.eq(checked.destination, "auth.json")
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

            test.eq(code(call(runner, "materialize", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "fg1"})), "CONFLICT")

            local mat2 = value(call(runner, "materialize", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "fg2"}))
            test.eq(mat2.generation, 2)
            test.eq(mat2.value, CODEX_FILE_SENTINEL)

            local after = value(call(runner, "check", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = attempt}))
            test.eq(after.materialization_generation, 2)
            clean(call(runner, "check", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = attempt}))

            local claude_proj = issue(user, ws, "claude_login", attempt)
            test.eq(claude_proj.destination, ".credentials.json")
            test.eq(claude_proj.projection_kind, "file")
            local claude_mat = value(call(runner, "materialize", {projection_id = claude_proj.projection_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "cg1"}))
            test.eq(claude_mat.destination, ".credentials.json")
            test.eq(claude_mat.projection_kind, "file")
            test.eq(claude_mat.value, CLAUDE_FILE_SENTINEL)
        end)
        test.it("fails closed on missing, invalid, empty or oversized login files", function()
            local ws = fresh("ws")
            admit_sources(ws)
            local attempt = fresh("attempt")

            value(call(manager, "define", {workspace_id = ws, name = "missing_login", provider = "codex", source = {kind = "fs_directory", ref = MISSING_LOGIN_SOURCE}}))
            local missing_proj = issue(user, ws, "missing_login", attempt)
            local missing_res = call(runner, "materialize", {projection_id = missing_proj.projection_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = fresh("gk")})
            test.eq(code(missing_res), "UNAVAILABLE")

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

            -- UNPRIVILEGED_LOGIN_SOURCE is present in bee:credential_sources allowlist metadata,
            -- but absent from bee:credential_file_policy resources.
            local defined = value(call(manager, "define", {workspace_id = ws, name = "unprivileged", provider = "codex", source = {kind = "fs_directory", ref = UNPRIVILEGED_LOGIN_SOURCE}}))
            test.eq(defined.destination, "auth.json")
            test.eq(defined.projection_kind, "file")
            clean(call(manager, "define", {workspace_id = ws, name = "unprivileged", provider = "codex", source = {kind = "fs_directory", ref = UNPRIVILEGED_LOGIN_SOURCE}}))

            local proj = issue(user, ws, "unprivileged", attempt)
            test.eq(proj.destination, "auth.json")
            test.eq(proj.projection_kind, "file")
            clean(call(user, "issue_projection", {workspace_id = ws, name = "unprivileged", audience = USER, attempt_id = attempt, profile_id = "batch", profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = fresh("key")}))

            local checked = value(call(runner, "check", {projection_id = proj.projection_id, subject = USER, audience = USER, attempt_id = attempt}))
            test.eq(checked.destination, "auth.json")
            clean(call(runner, "check", {projection_id = proj.projection_id, subject = USER, audience = USER, attempt_id = attempt}))

            -- Materialization attempts to read via fs.get; fails closed because registry source metadata alone cannot grant filesystem access
            local res = call(runner, "materialize", {projection_id = proj.projection_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = fresh("gk")})
            test.eq(code(res), "UNAVAILABLE")
            clean(res)
        end)
        test.it("proves ordinary caller cannot directly read login file or bypass materializer enforcement", function()
            local ws = fresh("ws")
            admit_sources(ws)
            write_file(CODEX_LOGIN_SOURCE, "auth.json", CODEX_FILE_SENTINEL)
            write_file(CLAUDE_LOGIN_SOURCE, ".credentials.json", CLAUDE_FILE_SENTINEL)

            value(call(manager, "define", {workspace_id = ws, name = "codex_login", provider = "codex", source = {kind = "fs_directory", ref = CODEX_LOGIN_SOURCE}}))
            local attempt = fresh("attempt")
            local proj = issue(user, ws, "codex_login", attempt)
            local proj_id = proj.projection_id :: string

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
            local admitted = caller(USER, {"bee.credentials:fs_test_policy"})
            local positive, positive_error = admitted:call("bee.credentials:probe_direct_fs_read", CODEX_LOGIN_SOURCE)
            if positive_error or type(positive) ~= "table" then error("direct read control did not execute") end
            test.is_true(positive.ok)
            test.eq(positive.value, CODEX_FILE_SENTINEL)
            for _, ordinary in ipairs({user, manager, outsider}) do
                local denied, denied_error = ordinary:call("bee.credentials:probe_direct_fs_read", CODEX_LOGIN_SOURCE)
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
        test.it("proves secrets absent from definition/projection/materialization ledger DB and non-materialization replies", function()
            local ws = fresh("ws")
            admit_sources(ws)
            write_file(CODEX_LOGIN_SOURCE, "auth.json", CODEX_FILE_SENTINEL)
            write_file(CLAUDE_LOGIN_SOURCE, ".credentials.json", CLAUDE_FILE_SENTINEL)

            -- 1. All non-materialization replies carry only metadata and digests, never secret bytes
            local codex_def = call(manager, "define", {workspace_id = ws, name = "codex_login", provider = "codex", source = {kind = "fs_directory", ref = CODEX_LOGIN_SOURCE}})
            test.is_true(codex_def.ok)
            clean(codex_def)

            local claude_def = call(manager, "define", {workspace_id = ws, name = "claude_login", provider = "claude", source = {kind = "fs_directory", ref = CLAUDE_LOGIN_SOURCE}})
            test.is_true(claude_def.ok)
            clean(claude_def)

            local env_def = call(manager, "define", {workspace_id = ws, name = "env_login", provider = "claude", source = {kind = "env_variable", ref = SOURCE}})
            test.is_true(env_def.ok)
            clean(env_def)

            local listed = call(manager, "list", {workspace_id = ws})
            test.is_true(listed.ok)
            clean(listed)

            local attempt = fresh("attempt")
            local codex_proj = call(user, "issue_projection", {workspace_id = ws, name = "codex_login", audience = USER, attempt_id = attempt, profile_id = "batch", profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = fresh("k")})
            test.is_true(codex_proj.ok)
            clean(codex_proj)
            local proj_id = codex_proj.value.projection_id :: string

            local claude_proj = call(user, "issue_projection", {workspace_id = ws, name = "claude_login", audience = USER, attempt_id = attempt, profile_id = "batch", profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = fresh("k")})
            test.is_true(claude_proj.ok)
            clean(claude_proj)

            local checked = call(runner, "check", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = attempt})
            test.is_true(checked.ok)
            clean(checked)

            -- Materialize returns bytes once to admitted runner
            local mat = call(runner, "materialize", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = fresh("gk")})
            test.is_true(mat.ok)

            -- Subsequent replay conflict reply carries no secret bytes
            local conflict = call(runner, "materialize", {projection_id = proj_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = mat.value.generation_key})
            test.is_false(conflict.ok)
            clean(conflict)

            -- Revocation reply carries no secret bytes
            local rev = call(user, "revoke", {projection_id = proj_id})
            test.is_true(rev.ok)
            clean(rev)

            -- Workspace epoch advance reply carries no secret bytes
            local rev_all = call(manager, "revoke_all", {workspace_id = ws})
            test.is_true(rev_all.ok)
            clean(rev_all)

            -- Capabilities reply carries no secret bytes
            local caps = call(outsider, "capabilities", {})
            test.is_true(caps.ok)
            clean(caps)

            -- 2. Inspect the persistent database and ledger tables directly
            local res, rerr = cred_sources.database()
            if not res then error("database ref: " .. tostring(rerr)) end
            local db, derr = persist.open({resource = res, ledger = broker.LEDGER, migrations = migrations.all()})
            if not db then error("open db: " .. tostring(derr)) end

            local tables = {"bee_credential_definitions", "bee_credential_projections", "bee_credential_generations", "bee_credential_epochs", broker.LEDGER.table}
            for _, tbl in ipairs(tables) do
                local found, qerr = db:query("SELECT * FROM " .. tbl)
                if not found then error("query " .. tbl .. ": " .. tostring(qerr)) end
                for _, row in ipairs(found) do
                    local encoded = tostring(json.encode(row))
                    test.is_nil(encoded:find(SENTINEL, 1, true))
                    test.is_nil(encoded:find("sentinel-codex-tok-123", 1, true))
                    test.is_nil(encoded:find("sentinel-claude-key-456", 1, true))
                    test.is_nil(encoded:find("chatgpt", 1, true))
                    test.is_nil(encoded:find("sessionKey", 1, true))
                end
            end
            db:release()
        end)
    end)
end
return test.run_cases(define_tests)
