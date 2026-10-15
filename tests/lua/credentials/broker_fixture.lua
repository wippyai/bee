-- MIT. The credential broker with a sentinel secret: definitions stay under
-- the host allowlist, projections bind exactly, only an admitted
-- materializer receives bytes, and the sentinel never appears anywhere but
-- in that one reply.
local shared_authority = require("shared_authority")
local test = require("test")
local bounds = require("bounds")
local principals = require("principals")
local funcs = require("funcs")
local registry = require("registry")
local time = require("time")
local json = require("json")
local fs = require("fs")
local credential_protocol = require("credential_protocol")
local store = require("store")
local SENTINEL = "sentinel-secret-7f3a9c"
local SOURCE = "bee.tests.credentials:sentinel_key"
local MISSING_SOURCE = "bee.tests.credentials:missing_key"
local OTHER_SOURCE = "bee.tests.credentials:other_key"
local BROKEN_SOURCE = "bee.tests.credentials:broken_key"
local CODEX_LOGIN_SOURCE = "bee.tests.credentials:codex_login_fixture"
local CLAUDE_LOGIN_SOURCE = "bee.tests.credentials:claude_login_fixture"
local INVALID_LOGIN_SOURCE = "bee.tests.credentials:invalid_login_fixture"
local MISSING_LOGIN_SOURCE = "bee.tests.credentials:missing_login_fixture"
local UNPRIVILEGED_LOGIN_SOURCE = "bee.tests.credentials:unprivileged_login_fixture"
local UNREADABLE_LOGIN_SOURCE = "bee.tests.credentials:unreadable_login_fixture"
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
local fixture_milliseconds: integer? = nil
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end
local scope = shared_authority.scope

type Principal = {id: string, names: {string}}
local function caller(id: string, grants: {string}): Principal
    local names: {string} = {"bee.tests.credentials:client_test_policy"}
    for _, grant in ipairs(grants) do names[#names + 1] = grant end
    return {id = id, names = names}
end
-- A principal acts bound to one workspace; by default the one its request names.
local function bound(client: Principal, workspace_id: unknown): funcs.Executor
    return funcs.new():with_actor(principals.actor(client.id, workspace_id)):with_scope(scope(client.names))
end
local function executor(client: Principal, value: unknown): funcs.Executor
    local current = bound(client, principals.workspace(value))
    if fixture_milliseconds then return current:with_context({["bee.test.credentials.milliseconds"] = fixture_milliseconds}) end
    return current
end
local function with_clock(body: () -> ())
    fixture_milliseconds = math.floor(time.now():unix_nano() / 1000000)
    local ok, problem = pcall(body)
    fixture_milliseconds = nil
    if not ok then error(tostring(problem)) end
end
local function advance(milliseconds: integer)
    fixture_milliseconds = assert(fixture_milliseconds) + milliseconds
end
local manager = caller(MANAGER, {"bee.credentials.security:credential_manage_policy"})
local user = caller(USER, {"bee.credentials.security:credential_issue_policy"})
local other = caller(OTHER, {"bee.credentials.security:credential_issue_policy"})
local runner = caller(RUNNER, {"bee.credentials.security:credential_materialize_policy"})
local outsider = caller("bee.test.cred.outsider", {})
local function call(client: Principal, method: string, value: unknown): credential_protocol.Reply
    local reply, err = executor(client, value):call("bee.credentials.binding:" .. method, value)
    if err then error(method .. ": " .. tostring(err)) end
    return principals.reply(reply)
end
local function async_call(client: Principal, method: string, value: unknown): funcs.Future
    local future, err = executor(client, value):async("bee.credentials.binding:" .. method, value)
    if not future then error(method .. ": " .. tostring(err)) end
    return future
end
local function await_call(future: funcs.Future): credential_protocol.Reply
    local _, open = future:response():receive()
    if not open then error("credential call closed without a reply") end
    local payload, result_error = future:result()
    if result_error or not payload then error("credential call: " .. tostring(result_error)) end
    return principals.reply(payload:data())
end
local function value(reply: credential_protocol.Reply): {[string]: unknown}
    if not reply.ok then error(tostring(reply.error and reply.error.code) .. ": " .. tostring(reply.error and reply.error.message)) end
    return assert(bounds.object(reply.value))
end
local function code(reply: credential_protocol.Reply): string
    if reply.ok then error("expected a failure, got success") end
    return reply.error and reply.error.code or ""
end
local function clean(reply: credential_protocol.Reply)
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
local function fixture_file(ref: string, path: string): string
    local volume, err = fs.get(ref)
    if not volume then error("volume " .. ref .. ": " .. tostring(err)) end
    local file, open_error = volume:open("/" .. path, "r")
    if not file then error("read fixture " .. path .. ": " .. tostring(open_error)) end
    local content = file:read(4096)
    file:close()
    return type(content) == "string" and content or ""
end
local function has(items: {string}, wanted: string): boolean
    for _, item in ipairs(items) do if item == wanted then return true end end
    return false
end
local function admit_sources(workspace: string)
    local entry = registry.get("bee.credentials.env:credential_sources")
    if not entry then error("credential sources entry") end
    local data = assert(bounds.object(entry.data))
    data.sources = {{ref = SOURCE, workspace_id = "*", audience = USER, provider = "claude", projection_kinds = {"environment"}},
        {ref = MISSING_SOURCE, workspace_id = "*", audience = USER, provider = "claude", projection_kinds = {"environment"}},
        {ref = OTHER_SOURCE, workspace_id = workspace, audience = "*", provider = "codex", projection_kinds = {"environment"}},
        {ref = BROKEN_SOURCE, workspace_id = workspace, audience = "*", provider = "codex", projection_kinds = {"environment"}},
        {ref = CODEX_LOGIN_SOURCE, workspace_id = workspace, audience = USER, provider = "codex", projection_kinds = {"file"}, write_back = true,
            setup_path = ".codex/config.toml", setup_destination = ".codex/config.toml", setup_content_format = "opaque", setup_initialize_empty = true,
            auxiliary_files = {{source_prefix = ".codex/", destination_prefix = ".codex/", suffix = ".config.toml", content_format = "opaque"}}},
        {ref = CLAUDE_LOGIN_SOURCE, workspace_id = "*", audience = USER, provider = "claude", projection_kinds = {"file"}},
        {ref = INVALID_LOGIN_SOURCE, workspace_id = workspace, audience = USER, provider = "codex", projection_kinds = {"file"}},
        {ref = MISSING_LOGIN_SOURCE, workspace_id = workspace, audience = USER, provider = "codex", projection_kinds = {"file"}},
        {ref = UNREADABLE_LOGIN_SOURCE, workspace_id = workspace, audience = USER, provider = "codex", projection_kinds = {"file"}},
        {ref = UNPRIVILEGED_LOGIN_SOURCE, workspace_id = workspace, audience = USER, provider = "codex", projection_kinds = {"file"}, setup_path = AGY_ONBOARDING},
        {ref = CODEX_LOGIN_SOURCE, workspace_id = workspace, audience = USER, provider = "agy", projection_kinds = {"file"}, setup_path = AGY_ONBOARDING},
        {ref = CODEX_LOGIN_SOURCE, workspace_id = workspace, audience = USER, provider = "grok", projection_kinds = {"file"},
            path = ".grok/auth.json", write_back = true, setup_path = GROK_CONFIG, setup_destination = GROK_PRIVATE_BASE,
            setup_content_format = "opaque", setup_initialize_empty = true}}
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local file_policy = registry.get("bee.credentials.security:credential_file_policy")
    local write_policy = registry.get("bee.credentials.security:credential_file_write_policy")
    if not file_policy or not write_policy then error("credential file policy entry") end
    file_policy.data.policy.resources = {CODEX_LOGIN_SOURCE, CLAUDE_LOGIN_SOURCE, INVALID_LOGIN_SOURCE, MISSING_LOGIN_SOURCE, UNREADABLE_LOGIN_SOURCE}
    write_policy.data.policy.resources = {CODEX_LOGIN_SOURCE, CLAUDE_LOGIN_SOURCE, INVALID_LOGIN_SOURCE, MISSING_LOGIN_SOURCE}
    changes:update(file_policy)
    changes:update(write_policy)
    local applied, err = changes:apply()
    if not applied then error("admit sources: " .. tostring(err)) end
end
local function issue(client: Principal, workspace: string, name: string, attempt: string, extra: {[string]: unknown}?): {[string]: unknown}
    local request: {[string]: unknown} = {workspace_id = workspace, name = name, audience = USER, attempt_id = attempt, profile_id = "batch", profile_digest = DIGEST,
        binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = fresh("key")}
    for key, item in pairs(extra or {}) do request[key] = item end
    return value(call(client, "issue_projection", request))
end

return {USER = USER, OTHER = OTHER, SENTINEL = SENTINEL, SOURCE = SOURCE, MISSING_SOURCE = MISSING_SOURCE, OTHER_SOURCE = OTHER_SOURCE, BROKEN_SOURCE = BROKEN_SOURCE, CODEX_LOGIN_SOURCE = CODEX_LOGIN_SOURCE, CLAUDE_LOGIN_SOURCE = CLAUDE_LOGIN_SOURCE, INVALID_LOGIN_SOURCE = INVALID_LOGIN_SOURCE, MISSING_LOGIN_SOURCE = MISSING_LOGIN_SOURCE, UNPRIVILEGED_LOGIN_SOURCE = UNPRIVILEGED_LOGIN_SOURCE, UNREADABLE_LOGIN_SOURCE = UNREADABLE_LOGIN_SOURCE, AGY_ONBOARDING = AGY_ONBOARDING, ONBOARDING_SENTINEL = ONBOARDING_SENTINEL, GROK_CONFIG = GROK_CONFIG, GROK_PRIVATE_BASE = GROK_PRIVATE_BASE, GROK_CONFIG_SENTINEL = GROK_CONFIG_SENTINEL, CODEX_FILE_SENTINEL = CODEX_FILE_SENTINEL, CLAUDE_FILE_SENTINEL = CLAUDE_FILE_SENTINEL, GROK_FILE_SENTINEL = GROK_FILE_SENTINEL, DIGEST = DIGEST, fresh = fresh, caller = caller, bound = bound, with_clock = with_clock, advance = advance, manager = manager, user = user, other = other, runner = runner, outsider = outsider, call = call, async_call = async_call, await_call = await_call, value = value, code = code, clean = clean, write_file = write_file, fixture_file = fixture_file, has = has, admit_sources = admit_sources, issue = issue}
