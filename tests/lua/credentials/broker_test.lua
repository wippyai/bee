-- MIT. The credential broker with a sentinel secret: definitions stay under
-- the host allowlist, projections bind exactly, only an admitted
-- materializer receives bytes, and the sentinel never appears anywhere but
-- in that one reply.
local test = require("test")
local principals = require("principals")
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
local MISSING_SOURCE = "bee.credentials:missing_key"
local OTHER_SOURCE = "bee.credentials:other_key"
local BROKEN_SOURCE = "bee.credentials:broken_key"
local CODEX_LOGIN_SOURCE = "bee.credentials:codex_login_fixture"
local CLAUDE_LOGIN_SOURCE = "bee.credentials:claude_login_fixture"
local INVALID_LOGIN_SOURCE = "bee.credentials:invalid_login_fixture"
local MISSING_LOGIN_SOURCE = "bee.credentials:missing_login_fixture"
local UNPRIVILEGED_LOGIN_SOURCE = "bee.credentials:unprivileged_login_fixture"
local AGY_ONBOARDING = ".gemini/antigravity-cli/cache/onboarding.json"
local ONBOARDING_SENTINEL = "agy-onboarding-sentinel-42"
local GROK_CONFIG = ".grok/config.toml"
local GROK_PRIVATE_BASE = ".grok/.bee-global-config.toml"
local GROK_CONFIG_SENTINEL = "[ui]\ntheme = \"grok-config-sentinel-23\"\n[permission]\ndefault = \"ask\"\n"
local CODEX_FILE_SENTINEL = '{"access_token":"sentinel-codex-tok-123","auth_mode":"chatgpt"}'
local CLAUDE_FILE_SENTINEL = '{"sessionKey":"sentinel-claude-key-456"}'
local GROK_FILE_SENTINEL = '{"access_token":"sentinel-grok-token-789"}'
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
type Principal = {id: string, names: {string}}
local function caller(id: string, grants: {string}): Principal
    local names: {string} = {"bee.credentials:client_test_policy"}
    for _, grant in ipairs(grants) do names[#names + 1] = grant end
    return {id = id, names = names}
end
-- A principal acts bound to one workspace; by default the one its request names.
local function bound(client: Principal, workspace_id: unknown): funcs.Executor
    return funcs.new():with_actor(principals.actor(client.id, workspace_id)):with_scope(scope(client.names))
end
local function executor(client: Principal, value: unknown): funcs.Executor
    return bound(client, principals.workspace(value))
end
local manager = caller(MANAGER, {"bee.security.credentials:credential_manage_policy"})
local user = caller(USER, {"bee.security.credentials:credential_issue_policy"})
local other = caller(OTHER, {"bee.security.credentials:credential_issue_policy"})
local runner = caller(RUNNER, {"bee.security.credentials:credential_materialize_policy"})
local outsider = caller("bee.test.cred.outsider", {})
local function call(client: Principal, method: string, value: unknown): broker.Reply
    local reply, err = executor(client, value):call("bee.credentials.binding:" .. method, value)
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
    if encoded:find(ONBOARDING_SENTINEL, 1, true) then error("Agy onboarding leaked into a reply that must not carry it") end
    if encoded:find("grok-config-sentinel-23", 1, true) then error("Grok setup leaked into a reply that must not carry it") end
    if encoded:find("sentinel-grok-token-789", 1, true) then error("Grok login leaked into a reply that must not carry it") end
end
local function write_file(ref: string, path: string, content: string)
    local volume, err = fs.get(ref)
    if not volume then error("volume " .. ref .. ": " .. tostring(err)) end
    local parent = ""
    for segment in (path:match("^(.*)/[^/]+$") or ""):gmatch("[^/]+") do
        parent = parent == "" and segment or parent .. "/" .. segment
        if not volume:exists(parent) then
            local made, mkdir_error = volume:mkdir(parent)
            if not made then error("mkdir " .. parent .. ": " .. tostring(mkdir_error)) end
        end
    end
    local ok, werr = volume:writefile(path, content)
    if not ok then error("writefile " .. path .. ": " .. tostring(werr)) end
end
local function admit_sources(workspace: string)
    local entry = registry.get("bee:credential_sources")
    if not entry then error("credential sources entry") end
    local data = entry.data :: {[string]: unknown}
    data.sources = {{ref = SOURCE, workspace_id = "*", audience = USER, provider = "claude", projection_kinds = {"environment"}},
        {ref = MISSING_SOURCE, workspace_id = "*", audience = USER, provider = "claude", projection_kinds = {"environment"}},
        {ref = OTHER_SOURCE, workspace_id = workspace, audience = "*", provider = "codex", projection_kinds = {"environment"}},
        {ref = BROKEN_SOURCE, workspace_id = workspace, audience = "*", provider = "codex", projection_kinds = {"environment"}},
        {ref = CODEX_LOGIN_SOURCE, workspace_id = workspace, audience = USER, provider = "codex", projection_kinds = {"file"}},
        {ref = CLAUDE_LOGIN_SOURCE, workspace_id = "*", audience = USER, provider = "claude", projection_kinds = {"file"}},
        {ref = INVALID_LOGIN_SOURCE, workspace_id = workspace, audience = USER, provider = "codex", projection_kinds = {"file"}},
        {ref = MISSING_LOGIN_SOURCE, workspace_id = workspace, audience = USER, provider = "codex", projection_kinds = {"file"}},
        {ref = UNPRIVILEGED_LOGIN_SOURCE, workspace_id = workspace, audience = USER, provider = "codex", projection_kinds = {"file"}, setup_path = AGY_ONBOARDING},
        {ref = CODEX_LOGIN_SOURCE, workspace_id = workspace, audience = USER, provider = "agy", projection_kinds = {"file"}, setup_path = AGY_ONBOARDING},
        {ref = CODEX_LOGIN_SOURCE, workspace_id = workspace, audience = USER, provider = "grok", projection_kinds = {"file"},
            path = ".grok/auth.json", setup_path = GROK_CONFIG, setup_destination = GROK_PRIVATE_BASE, setup_content_format = "opaque"}}
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local file_policy = registry.get("bee.security.credentials:credential_file_policy")
    if not file_policy then error("credential file policy entry") end
    file_policy.data.policy.resources = {CODEX_LOGIN_SOURCE, CLAUDE_LOGIN_SOURCE, INVALID_LOGIN_SOURCE, MISSING_LOGIN_SOURCE}
    changes:update(file_policy)
    local applied, err = changes:apply()
    if not applied then error("admit sources: " .. tostring(err)) end
end
local function issue(client: Principal, workspace: string, name: string, attempt: string, extra: {[string]: unknown}?): {[string]: unknown}
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
            test.eq(defined.optional, false)
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
            local optional_name = fresh("optional-env")
            local optional = value(call(manager, "define", {workspace_id = workspace, name = optional_name, provider = "claude", source = {kind = "env_variable", ref = MISSING_SOURCE}, optional = true}))
            test.eq(optional.optional, true)
            local optional_attempt = fresh("attempt")
            local optional_projection = issue(user, workspace, optional_name, optional_attempt)
            local absent = value(call(runner, "materialize", {projection_id = optional_projection.projection_id, subject = USER, audience = USER,
                attempt_id = optional_attempt, generation_key = fresh("generation")}))
            test.eq(absent.projection_kind, "environment")
            test.eq(absent.destination, "ANTHROPIC_API_KEY")
            test.eq(absent.optional, true)
            test.eq(absent.present, false)
            test.is_nil(absent.value)
            test.eq(code(call(manager, "define", {workspace_id = workspace, name = fresh("optional-type"), provider = "claude", source = {kind = "env_variable", ref = SOURCE}, optional = "true"})), "INVALID")
        end)
        test.it("issues and materializes projections only in the workspace the principal is bound to", function()
            local attempt = fresh("attempt")
            local request = {workspace_id = workspace, name = "anthropic", audience = USER, attempt_id = attempt, profile_id = "batch",
                profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = fresh("key")}
            local elsewhere = fresh("elsewhere")
            for _, bound_to in ipairs({elsewhere, false}) do
                local reply, err = bound(user, bound_to or nil):call("bee.credentials.binding:issue_projection", request)
                if err then error(tostring(err)) end
                test.eq(code(reply :: broker.Reply), "DENIED")
            end
            local projection = issue(user, workspace, "anthropic", attempt)
            local app_runner = caller("bee.test.cred.app_runner", {"bee.security.credentials:credential_materialize_workspace_policy"})
            local use = {projection_id = projection.projection_id, subject = USER, audience = USER, attempt_id = attempt}
            local foreign, foreign_error = bound(app_runner, elsewhere):call("bee.credentials.binding:check", use)
            if foreign_error then error(tostring(foreign_error)) end
            test.eq(code(foreign :: broker.Reply), "DENIED")
            local own, own_error = bound(app_runner, workspace):call("bee.credentials.binding:check", use)
            if own_error then error(tostring(own_error)) end
            test.eq((value(own :: broker.Reply)).projection_id, projection.projection_id)
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
            test.eq(codex_def.optional, false)
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

            local source_entry = registry.get("bee:credential_sources")
            if not source_entry then error("sources entry") end
            local source_data = source_entry.data :: {[string]: unknown}
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
                local entry = registry.get("bee:credential_sources")
                if not entry then error("sources") end
                for _, source in ipairs(entry.data.sources :: {{[string]: unknown}}) do
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
            local format_entry = registry.get("bee.driver.codex:credential_format")
            if not format_entry then error("codex credential format") end
            local format_data = format_entry.data :: {[string]: unknown}
            local file_data = format_data.file :: {[string]: unknown}
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
            local entry = registry.get("bee:credential_sources")
            if not entry then error("credential sources entry") end
            for _, item in ipairs((entry.data :: {[string]: unknown}).sources :: {{[string]: unknown}}) do
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
            local definitions = listed.definitions :: {{[string]: unknown}}
            local persisted: {[string]: unknown}? = nil
            for _, item in ipairs(definitions) do
                if item.name == "agy_setup" then persisted = item end
            end
            if not persisted then error("Agy setup definition disappeared") end
            test.eq(persisted.digest, digest)
            test.eq(persisted.revision, revision)
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

                local entry = registry.get("bee:credential_sources")
                if not entry then error("credential sources entry") end
                local changed = false
                for _, item in ipairs((entry.data :: {[string]: unknown}).sources :: {{[string]: unknown}}) do
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

            -- UNPRIVILEGED_LOGIN_SOURCE is present in bee:credential_sources allowlist metadata,
            -- but absent from bee.security.credentials:credential_file_policy resources.
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
            local positive, positive_error = bound(admitted, ws):call("bee.credentials:probe_direct_fs_read", CODEX_LOGIN_SOURCE)
            if positive_error or type(positive) ~= "table" then error("direct read control did not execute") end
            test.is_true(positive.ok)
            test.eq(positive.value, CODEX_FILE_SENTINEL)
            for _, ordinary in ipairs({user, manager, outsider}) do
                local denied, denied_error = bound(ordinary, ws):call("bee.credentials:probe_direct_fs_read", CODEX_LOGIN_SOURCE)
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
                    test.is_nil(encoded:find(ONBOARDING_SENTINEL, 1, true))
                    test.is_nil(encoded:find("grok-config-sentinel-23", 1, true))
                    test.is_nil(encoded:find("sentinel-grok-token-789", 1, true))
                end
            end
            db:release()
        end)
    end)
end
return test.run_cases(define_tests)
