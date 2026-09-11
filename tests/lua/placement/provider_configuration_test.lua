-- MIT. Native placement acceptance for a provider configured through a third
-- driver binding. The denied paths must leave no durable placement intent.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local json = require("json")
local service = require("service")
local store = require("store")
local homes = require("homes")
local hash = require("hash")
local time = require("time")
local exec = require("exec")
local quote = require("quote")

local OWNER = "bee.test.third_driver"
local DIGEST = string.rep("b", 64)
local ROOT = "bee.placement.native:project_fixture"
local POLICY = "bee.placement.native:fixture_agent_policy"
local PROVIDER = "bee.placement.native:fixture_agent_provider"
local BINDING = "bee.placement.native:fixture_agent_binding"
local ACTIVATION = "bee:harness_activation"
local ROOTS = "bee.placement.native:admitted_roots"
local counter = 0
type RegistryState = {activation: {[string]: unknown}, roots: {[string]: unknown}}

local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-third-driver-" .. tostring(counter) .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000))
end

local function caller(actor: string)
    local policies: {security.Policy} = {}
    for index, name in ipairs({"bee.placement.native:client_test_policy", "bee:resource_manage_policy", "bee:resource_grant_policy", "bee:credential_manage_policy", "bee:credential_issue_policy"}) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    return funcs.new():with_actor(security.new_actor(actor)):with_scope(security.new_scope(policies))
end

local function call(actor: string, method: string, value: unknown): service.Reply
    local reply, err = caller(actor):call("bee.placement.native:" .. method, value)
    if err then error(method .. ": " .. tostring(err)) end
    return reply :: service.Reply
end

local function admit_root()
    local entry = registry.get(ROOTS)
    if not entry then error("admitted roots entry") end
    local data = entry.data :: {[string]: unknown}
    local roots = data.roots :: {{[string]: unknown}}
    for _, root in ipairs(roots) do
        if root.root_ref == ROOT then return end
    end
    roots[#roots + 1] = {root_ref = ROOT, access = "write"}
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("admit root: " .. tostring(err)) end
end

local function clone_object(value: unknown): {[string]: unknown}
    local encoded, encode_error = json.encode(value)
    if not encoded then error(tostring(encode_error or "encode registry state")) end
    local copied, decode_error = json.decode(encoded)
    if type(copied) ~= "table" then error(tostring(decode_error or "decode registry state")) end
    return copied :: {[string]: unknown}
end

local function registry_state(): RegistryState
    local activation = registry.get(ACTIVATION)
    local roots = registry.get(ROOTS)
    if not activation or not roots then error("registry state entries") end
    return {activation = clone_object(activation.data), roots = clone_object(roots.data)}
end

local function restore_registry_state(state: RegistryState)
    local activation = registry.get(ACTIVATION)
    local roots = registry.get(ROOTS)
    if not activation or not roots then error("registry state entries disappeared") end
    activation.data = clone_object(state.activation)
    roots.data = clone_object(state.roots)
    local changes = registry.snapshot():changes()
    changes:update(activation)
    changes:update(roots)
    local applied, err = changes:apply()
    if not applied then error("restore registry state: " .. tostring(err)) end
end

local function set_activation(enabled: boolean)
    local entry = registry.get(ACTIVATION)
    if not entry then error("activation entry") end
    local data = entry.data :: {[string]: unknown}
    local current = data.bindings :: {unknown}
    local bindings: {string} = {}
    for _, item in ipairs(current) do
        local binding = tostring(item)
        if binding ~= BINDING then bindings[#bindings + 1] = binding end
    end
    if enabled then bindings[#bindings + 1] = BINDING end
    data.bindings = bindings
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("set activation: " .. tostring(err)) end
end

local function provider_configuration(): {[string]: string}
    local content = '{"provider_ref":"' .. PROVIDER .. '","model":"terra"}\n'
    local digest = assert(hash.sha256(content))
    return {revision = "bee.fixture-agent-config@1", path = ".fixture-agent/provider.json", content = content, digest = digest, provider_ref = PROVIDER}
end

local function launch(attempt_id: string): {[string]: unknown}
    return {idempotency_key = fresh("key"), owner_id = OWNER, owner_incarnation = 1, action_id = fresh("action"), attempt_id = attempt_id,
        binding_ref = BINDING, policy_ref = POLICY, profile_id = "batch", binding_digest = DIGEST, profile_digest = DIGEST,
        launch = {executable = "sh", argv = {"-c", "test -s \"$HOME/.fixture-agent/provider.json\""}, environment = {}, working_directory_ref = "project", readiness = "none"},
        configuration = provider_configuration(), resources = {{name = "project", grant_ref = "grant-1", root_ref = ROOT, subpath = "", access = "write", purpose = "project"}},
        environment = {}, required_cleanup = "direct_process", required_exit_observation = "eof_gated", timeouts = {start_ms = 10000, stop_grace_ms = 500}}
end

local function denied_without_intent(request: {[string]: unknown}, expected: string)
    local refused = call(OWNER, "prepare", request)
    test.is_false(refused.ok)
    test.eq(refused.error and refused.error.code, "DENIED")
    if expected ~= "" then test.is_true(tostring(refused.error and refused.error.message):find(expected, 1, true) ~= nil) end
    local db, open_error = store.open()
    if not db then error(open_error or "placement store") end
    local attempt, read_error = store.attempt(db, request.attempt_id :: string)
    db:release()
    if read_error then error(read_error) end
    test.is_nil(attempt)
end

local function shell(command: string): string
    local executor = assert(exec.get("bee.placement.native:executor"))
    local proc = assert(executor:exec(command))
    local stdout = proc:stdout_stream()
    assert(proc:start())
    local output = ""
    while true do
        local chunk: unknown = stdout:read(4096)
        if type(chunk) ~= "string" or chunk == "" then break end
        output = output .. (chunk :: string)
    end
    proc:wait()
    stdout:close()
    executor:release()
    return output
end

local function run_command(argv: {string}): string
    return shell(quote.line(argv))
end

local function wait_for_exit(attempt_id: string)
    local deadline = time.now():unix_nano() + 5000 * 1000000
    while time.now():unix_nano() < deadline do
        local status = call(OWNER, "status", {attempt_id = attempt_id})
        if status.ok and type(status.value) == "table" and (status.value :: {[string]: unknown}).attempt ~= nil then
            local attempt = (status.value :: {[string]: unknown}).attempt :: {[string]: unknown}
            if attempt.execution_state == "exited" then
                local exit = attempt.exit
                if type(exit) ~= "table" or (exit :: {[string]: unknown}).code ~= 0 then error("third-driver child exited unsuccessfully") end
                return
            end
        end
        time.sleep("50ms")
    end
    error("third-driver child did not exit")
end

local function cleanup_attempt(attempt_id: string)
    local status = call(OWNER, "status", {attempt_id = attempt_id})
    if status.ok and type(status.value) == "table" then
        local attempt = (status.value :: {[string]: unknown}).attempt
        if type(attempt) == "table" and (attempt :: {[string]: unknown}).execution_state ~= "exited" then
            call(OWNER, "stop", {attempt_id = attempt_id, mode = "forced"})
        end
    end
    local deadline = time.now():unix_nano() + 5000 * 1000000
    while time.now():unix_nano() < deadline do
        local current = call(OWNER, "status", {attempt_id = attempt_id})
        if current.ok and type(current.value) == "table" then
            local attempt = (current.value :: {[string]: unknown}).attempt
            if type(attempt) == "table" and (attempt :: {[string]: unknown}).execution_state == "exited" then break end
        end
        time.sleep("50ms")
    end
    call(OWNER, "cleanup", {attempt_id = attempt_id})
end

local function define_tests()
    test.describe("Third driver provider configuration", function()
        local original = registry_state()
        admit_root()
        test.it("materializes the activated third-driver provider file and rejects forged or inactive requests without intent", function()
            local prepared_attempt_id: string? = nil
            local body_ok, body_error = pcall(function()
                set_activation(true)
                local forged = launch(fresh("attempt"))
                local configuration = forged.configuration :: {[string]: unknown}
                local content = (configuration.content :: string) .. "forged=true\n"
                configuration.content = content
                configuration.digest = assert(hash.sha256(content))
                denied_without_intent(forged, "does not match")

                set_activation(false)
                local inactive = launch(fresh("attempt"))
                denied_without_intent(inactive, "not activated")

                set_activation(true)
                local request = launch(fresh("attempt"))
                local prepared_reply = call(OWNER, "prepare", request)
                test.is_true(prepared_reply.ok)
                local prepared = prepared_reply.value :: {[string]: unknown}
                prepared_attempt_id = prepared.attempt_id :: string
                test.eq(prepared.execution_state, "intended")
                local started_reply = call(OWNER, "start", {attempt_id = prepared.attempt_id})
                test.is_true(started_reply.ok)
                local started = started_reply.value :: {[string]: unknown}
                test.eq(started.execution_state, "running")

                local key = assert(homes.attempt_key(OWNER, prepared.attempt_id :: string))
                local path = assert(homes.os_path("/attempts/" .. key .. "/home/.fixture-agent/provider.json"))
                local bytes = run_command({"wc", "-c", path}):match("%d+")
                test.is_true(bytes ~= nil and tonumber(bytes) ~= nil and tonumber(bytes) > 0)
                test.is_true(path:find("/.fixture-agent/provider.json", 1, true) ~= nil)
                test.is_false(path:find("/.codex/config.toml", 1, true) ~= nil)
                test.eq(run_command({"cat", path}), (request.configuration :: {[string]: unknown}).content)

                wait_for_exit(prepared.attempt_id :: string)
                local cleaned = call(OWNER, "cleanup", {attempt_id = prepared.attempt_id})
                test.is_true(cleaned.ok)
                prepared_attempt_id = nil
            end)
            local cleanup_ok, cleanup_error = pcall(function()
                if prepared_attempt_id then cleanup_attempt(prepared_attempt_id) end
            end)
            local restore_ok, restore_error = pcall(function() restore_registry_state(original) end)
            if not body_ok then error(tostring(body_error)) end
            if not cleanup_ok then error("test attempt cleanup: " .. tostring(cleanup_error)) end
            if not restore_ok then error(tostring(restore_error)) end
        end)
    end)
end

return test.run_cases(define_tests)
