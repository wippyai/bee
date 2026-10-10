-- MIT. The native placement against the runtime it runs on: intent before
-- creation, fail-closed capability, a full runner flow with acknowledged
-- streams, stop escalation, uncertainty without identity, cleanup only
-- after a proven exit.
local test = require("test")
local bounds = require("bounds")
local principals = require("principals")
local funcs = require("funcs")
local security = require("security")
local process = require("process")
local channel = require("channel")
local time = require("time")
local registry = require("registry")
local exec = require("exec")
local service = require("service")
local configuration = require("configuration")
local grok_configuration = require("grok_configuration")
local grok_launch = require("grok_launch")
local claude_launch = require("claude_launch")
local codex_launch = require("codex_launch")
local agy_launch = require("agy_launch")
local muse_launch = require("muse_launch")
local opencode_launch = require("opencode_launch")
local configuration_protocol = require("configuration_protocol")
local preferences = require("preferences")
local profile_values = require("profile_values")
local json = require("json")
local store = require("store")
local resources = require("resources")
local request_codec = require("request_codec")
local homes = require("homes")
local quote = require("quote")
local types = require("types")
local placement_decode = require("placement_decode")
local CODEX_LOGIN_FORMAT = {schema_revision = "bee.credential-format@1", file = {
    path = ".codex/auth.json", content_format = "json", initialize = {}}}
local CLAUDE_LOGIN_FORMAT = {schema_revision = "bee.credential-format@1", file = {
    path = ".claude/.credentials.json", content_format = "json",
    initialize = {{path = ".claude.json", content = '{"hasCompletedOnboarding":true}'}}}}
local OWNER = "bee.test.owner"
local DIGEST = string.rep("b", 64)
local ROOT = "bee.placement.native:project_fixture"
local POLICY = "bee.placement.native:test_launch_policy"
local NO_PROVIDER_POLICY = "bee.placement.native:test_launch_policy_without_provider"
local FIXTURE_BINDING = "bee.placement.native:fixture_agent_binding"
local counter = 0

type RegistryInput = {id: string, kind: string, meta: {[string]: unknown}, data: unknown, dependency_root: boolean}
local function registry_input(value: {[string]: unknown}): RegistryInput
    local id, kind, meta, dependency_root = value.id, value.kind, value.meta, value.dependency_root
    assert(type(id) == "string" and type(kind) == "string", "fixture registry entry identity")
    local metadata: {[string]: unknown} = {}
    if meta ~= nil then
        assert(type(meta) == "table", "fixture registry metadata")
        for key, item in pairs(meta) do metadata[key] = item end
    end
    assert(dependency_root == nil or type(dependency_root) == "boolean", "fixture registry dependency root")
    return {id = id, kind = kind, meta = metadata, data = value.data, dependency_root = dependency_root == true}
end

local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end
-- A caller is bound to the workspace it acts in, as host-issued principals are.
local function caller(actor: string, workspace_id: unknown)
    local policies: {security.Policy} = {}
    for index, name in ipairs({"bee.placement.native:client_test_policy", "bee.resources.security:resource_manage_policy", "bee.resources.security:resource_grant_policy", "bee.credentials.security:credential_manage_policy", "bee.credentials.security:credential_issue_policy"}) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    return funcs.new():with_actor(principals.actor(actor, workspace_id)):with_scope(security.new_scope(policies))
end
local SENTINEL = "placement-sentinel-4e5f6a"
local function credential_call(method: string, value: unknown): {[string]: unknown}
    local reply, err = caller(OWNER, principals.workspace(value)):call("bee.credentials.binding:" .. method, value)
    if err then error(method .. ": " .. tostring(err)) end
    local typed = principals.reply(reply)
    if not typed.ok then error(method .. ": " .. tostring(typed.error and typed.error.code) .. ": " .. tostring(typed.error and typed.error.message)) end
    return assert(bounds.object(typed.value))
end
local function admit_credential_source()
    local entry = registry.get("bee.credentials.env:credential_sources")
    if not entry then error("credential sources entry") end
    local data = assert(bounds.object(entry.data))
    local list = principals.objects(data.sources)
    data.sources = list
    for _, item in ipairs(list) do
        if item.ref == "bee.placement.native:sentinel_key" then return end
    end
    list[#list + 1] = {ref = "bee.placement.native:sentinel_key", workspace_id = "*", audience = OWNER, provider = "claude", projection_kinds = {"environment"}}
    local changes = registry.snapshot():changes()
    changes:update(registry_input(entry))
    local applied, err = changes:apply()
    if not applied then error("admit credential source: " .. tostring(err)) end
end
local function admit_login_source(source: string, private_codex_home: boolean?)
    local entry = registry.get("bee.credentials.env:credential_sources")
    if not entry then error("credential sources entry") end
    local data = assert(bounds.object(entry.data))
    local list = principals.objects(data.sources)
    data.sources = list
    local matched = false
    for _, item in ipairs(list) do
        if item.ref == source and item.provider == "codex" and item.audience == OWNER then
            item.path = private_codex_home and ".codex/auth.json" or nil
            item.write_back = private_codex_home == true
            item.setup_path = private_codex_home and ".codex/config.toml" or nil
            item.setup_destination = private_codex_home and ".codex/config.toml" or nil
            item.setup_content_format = private_codex_home and "opaque" or nil
            item.setup_initialize_empty = private_codex_home and true or nil
            item.auxiliary_files = private_codex_home and {{source_prefix = ".codex/", destination_prefix = ".codex/",
                suffix = ".config.toml", content_format = "opaque"}} or nil
            matched = true
        end
    end
    if not matched then
        local source_row: {[string]: unknown} = {ref = source, workspace_id = "*", audience = OWNER, provider = "codex", projection_kinds = {"file"}}
        if private_codex_home then
            source_row.path = ".codex/auth.json"
            source_row.write_back = true
            source_row.setup_path = ".codex/config.toml"
            source_row.setup_destination = ".codex/config.toml"
            source_row.setup_content_format = "opaque"
            source_row.setup_initialize_empty = true
            source_row.auxiliary_files = {{source_prefix = ".codex/", destination_prefix = ".codex/", suffix = ".config.toml", content_format = "opaque"}}
        end
        list[#list + 1] = source_row
    end
    local file_policy = registry.get("bee.credentials.security:credential_file_policy")
    local write_policy = registry.get("bee.credentials.security:credential_file_write_policy")
    if not file_policy or not write_policy then error("credential file policy entry") end
    file_policy.data.policy.resources = {source}
    write_policy.data.policy.resources = {source}
    local changes = registry.snapshot():changes()
    changes:update(registry_input(entry))
    changes:update(file_policy)
    changes:update(write_policy)
    local applied, apply_error = changes:apply()
    if not applied then error("admit login source: " .. tostring(apply_error)) end
end
local function admit_claude_login_source(source: string)
    local entry = registry.get("bee.credentials.env:credential_sources")
    if not entry then error("credential sources entry") end
    local data = assert(bounds.object(entry.data))
    local list = principals.objects(data.sources)
    data.sources = list
    local matched = false
    for _, item in ipairs(list) do
        if item.ref == source and item.provider == "claude" and item.audience == OWNER then
            matched = true
        end
    end
    if not matched then
        list[#list + 1] = {ref = source, workspace_id = "*", audience = OWNER, provider = "claude", projection_kinds = {"file"},
            path = ".claude/.credentials.json", write_back = false, setup_path = ".claude/settings.json",
            setup_destination = ".claude/settings.json", setup_content_format = "opaque"}
    end
    local file_policy = registry.get("bee.credentials.security:credential_file_policy")
    local write_policy = registry.get("bee.credentials.security:credential_file_write_policy")
    if not file_policy or not write_policy then error("credential file policy entry") end
    file_policy.data.policy.resources = {source}
    write_policy.data.policy.resources = {source}
    local changes = registry.snapshot():changes()
    changes:update(registry_input(entry))
    changes:update(file_policy)
    changes:update(write_policy)
    local applied, apply_error = changes:apply()
    if not applied then error("admit Claude login source: " .. tostring(apply_error)) end
end
local function admit_grok_login_source(source: string)
    local entry = registry.get("bee.credentials.env:credential_sources")
    if not entry then error("credential sources entry") end
    local data = assert(bounds.object(entry.data))
    local list = principals.objects(data.sources)
    data.sources = list
    for _, item in ipairs(list) do
        if item.ref == source and item.provider == "grok" and item.audience == OWNER then return end
    end
    list[#list + 1] = {ref = source, workspace_id = "*", audience = OWNER, provider = "grok", projection_kinds = {"file"},
        path = ".grok/auth.json", setup_path = ".grok/config.toml",
        setup_destination = ".grok/.bee-global-config.toml", setup_content_format = "opaque", setup_initialize_empty = true, write_back = true}
    local file_policy = registry.get("bee.credentials.security:credential_file_policy")
    local write_policy = registry.get("bee.credentials.security:credential_file_write_policy")
    if not file_policy or not write_policy then error("credential file policy entry") end
    file_policy.data.policy.resources = {source}
    write_policy.data.policy.resources = {source}
    local changes = registry.snapshot():changes()
    changes:update(registry_input(entry))
    changes:update(file_policy)
    changes:update(write_policy)
    local applied, apply_error = changes:apply()
    if not applied then error("admit Grok login source: " .. tostring(apply_error)) end
end
local function resource_mode(mode: string)
    local entry = registry.get("bee.placement.native.env:placement_resource_mode")
    if not entry then error("resource mode entry") end
    local data = assert(bounds.object(entry.data))
    data.mode = mode
    local changes = registry.snapshot():changes()
    changes:update(registry_input(entry))
    local applied, err = changes:apply()
    if not applied then error("set resource mode: " .. tostring(err)) end
end
local function resource_call(method: string, value: unknown): {[string]: unknown}
    local reply, err = caller(OWNER, principals.workspace(value)):call("bee.resources.binding:" .. method, value)
    if err then error(method .. ": " .. tostring(err)) end
    local typed = principals.reply(reply)
    if not typed.ok then error(method .. ": " .. tostring(typed.error and typed.error.code) .. ": " .. tostring(typed.error and typed.error.message)) end
    return assert(bounds.object(typed.value))
end
local function call(actor: string, method: string, value: unknown): service.Reply
    local client = caller(actor, principals.workspace(value))
    local raw, err = client:call("bee.placement.native.binding:" .. method, value)
    if err then error(method .. ": " .. tostring(err)) end
    local reply = principals.reply(raw)
    if method ~= "start" or not reply.ok then return reply end
    local attempt = assert(placement_decode.attempt(reply.value))
    local deadline = time.after("30s")
    while attempt.execution_state == "starting" do
        local tick = time.after("10ms")
        local selected = channel.select({tick:case_receive(), deadline:case_receive()})
        assert(selected.ok and selected.channel ~= deadline, "test runner did not finish startup")
        local status_value, status_error = client:call("bee.placement.native.binding:status", {attempt_id = attempt.attempt_id})
        assert(not status_error, tostring(status_error))
        local status = principals.reply(status_value)
        assert(status.ok, status.error and status.error.message)
        attempt = assert(placement_decode.status(status.value)).attempt
    end
    return {ok = true, value = attempt}
end

local function value(reply: service.Reply): {[string]: unknown}
    if not reply.ok then error(tostring(reply.error and reply.error.code) .. ": " .. tostring(reply.error and reply.error.message)) end
    return assert(bounds.object(reply.value))
end
local function attempt_of(reply: service.Reply): types.Attempt
    return assert(placement_decode.attempt(value(reply)))
end
local function await(future: funcs.Future): unknown
    local _, open = future:response():receive()
    if not open then error("prepare race closed without a reply") end
    local payload, result_error = future:result()
    if result_error then error("prepare race: " .. tostring(result_error)) end
    if not payload then error("prepare race returned no reply") end
    local data = payload:data()
    if type(data) ~= "table" then error("prepare race reply returned " .. type(data)) end
    return data
end
local function launch(command: {string}, required: string): {[string]: unknown}
    local argv: {string} = {}
    for index = 2, #command do argv[index - 1] = command[index] end
    return {idempotency_key = fresh("key"), owner_id = OWNER, owner_incarnation = 1, action_id = fresh("action"), attempt_id = fresh("attempt"),
        binding_ref = FIXTURE_BINDING, policy_ref = NO_PROVIDER_POLICY, profile_id = "batch", binding_digest = DIGEST, profile_digest = DIGEST,
        launch = {executable = command[1], argv = argv, environment = {"PROBE_VALUE"}, working_directory_ref = "project", readiness = "none"},
        resources = {{name = "project", grant_ref = "grant-1", root_ref = ROOT, subpath = "", access = "write", purpose = "project"}},
        environment = {PROBE_VALUE = "probe-42"}, required_cleanup = required, required_exit_observation = "eof_gated", timeouts = {stop_grace_ms = 500}}
end
local function await_retained_runner(prepared: types.Attempt)
    local held = assert(process.listen("bee.test.native.held", {message = true}))
    local events = assert(process.events())
    local raw, start_error = caller(OWNER, nil):call("bee.placement.native.binding:start", {attempt_id = prepared.attempt_id})
    assert(not start_error, tostring(start_error))
    local started = attempt_of(principals.reply(raw))
    local runner = assert(started.runner)
    while true do
        local message = assert((held:receive()))
        if tostring(message:from()) == runner and message:payload():data().attempt_id == prepared.attempt_id then break end
    end
    assert(process.monitor(runner))
    assert(process.send(runner, "bee.test.native.release", {}))
    while true do
        local selected = channel.select({events:case_receive()})
        assert(selected.ok, "retention supervision channel closed")
        local event = selected.value
        if event.kind == process.event.EXIT and tostring(event.from) == runner then
            assert(not (event.result and event.result.error), "retention runner: " .. tostring(event.result and event.result.error))
            break
        end
        assert(event.kind ~= process.event.CANCEL, "retention observer cancelled")
    end
    process.unmonitor(runner)
    process.unlisten(held)
end
local function provider_home_fixtures(): {{provider: string, launch: {[string]: unknown}}}
    local result: {{provider: string, launch: {[string]: unknown}}} = {}
    local claude = assert(claude_launch.decode({profile_id = "batch", brief = "fixture"}))
    local codex = assert(codex_launch.decode({profile_id = "batch", brief = "fixture", config_profile = "ds-flash"}))
    local agy = assert(agy_launch.decode({profile_id = "batch", brief = "fixture"}))
    local grok = assert(grok_launch.decode({profile_id = "batch", brief = "fixture", permission_mode = "default"}))
    local muse = assert(muse_launch.decode({profile_id = "batch", brief = "fixture", approval_mode = "never"}))
    local opencode = assert(opencode_launch.decode({profile_id = "batch", brief = "fixture"}))
    result[1] = {provider = "claude", launch = assert(bounds.object(claude_launch.specification(claude)))}
    result[2] = {provider = "codex", launch = assert(bounds.object(codex_launch.specification(codex)))}
    result[3] = {provider = "agy", launch = assert(bounds.object(agy_launch.specification(agy)))}
    result[4] = {provider = "grok", launch = assert(bounds.object(grok_launch.specification(grok)))}
    result[5] = {provider = "muse", launch = assert(bounds.object(muse_launch.specification(muse)))}
    result[6] = {provider = "opencode", launch = assert(bounds.object(opencode_launch.specification(opencode)))}
    return result
end
local function provider_configuration(): {[string]: unknown}
    local provider = registry.get("bee.placement.native:codex_test_provider")
    if not provider then error("provider entry") end
    local decoded, decode_error = configuration.decode("bee.placement.native:codex_test_provider", provider)
    if not decoded then error(tostring(decode_error)) end
    local rendered, render_error = configuration.projection(decoded)
    if not rendered then error(tostring(render_error)) end
    -- The provider projection includes its own diagnostic fields; the native
    -- launch boundary accepts only the materialized configuration contract.
    return {revision = rendered.revision, path = rendered.path, content = rendered.content,
        digest = rendered.digest, provider_ref = rendered.provider_ref}
end
local function update_codex_provider(base_url: string, model: string)
    local provider = registry.get("bee.placement.native:codex_test_provider")
    if not provider then error("provider entry") end
    local data = assert(bounds.object(provider.data))
    data.base_url = base_url
    data.model = model
    local changes = registry.snapshot():changes()
    changes:update(provider)
    local applied, err = changes:apply()
    if not applied then error("update codex provider: " .. tostring(err)) end
end
local function provider_configuration_digest(policy_ref: string?): string
    local policy = assert(bounds.object(assert(registry.get(policy_ref or POLICY)).data))
    local descriptor = assert(profile_values.schema("bee.driver.codex.binding:binding"))
    local effective = assert(preferences.apply(policy, nil, descriptor))
    local provider_ref = bounds.id(effective.provider_ref)
    local provider = provider_ref and assert(registry.get(provider_ref)) or nil
    local digest, digest_error = configuration_protocol.digest("bee.driver.codex.binding:binding", {
        provider_ref = provider_ref, provider = provider, option_values = effective.prepare_options, fixture = true}, "bee.driver.codex.binding:configure")
    if not digest then error(tostring(digest_error)) end
    return digest
end
local function retained_launch(owner: string, session_ref: string, marker: string): {[string]: unknown}
    local request = launch({"sh", "-c", "printf '" .. marker .. "\\n' >> \"$HOME/marker\""}, "direct_process")
    request.owner_id = owner
    request.session_ref = session_ref
    request.policy_ref = POLICY
    request.binding_ref = "bee.driver.codex.binding:binding"
    local declared = assert(bounds.object(request.launch))
    declared.home_ref = "session"
    local resources = principals.objects(request.resources)
    request.resources = resources
    resources[#resources + 1] = {name = "session", grant_ref = "session-grant", root_ref = ROOT, subpath = "", access = "write", purpose = "session"}
    request.configuration_digest = provider_configuration_digest()
    return request
end
local function grok_composition_request(attempt_id: string, session_ref: string, projection_id: string,
    base_path: string): types.LaunchRequest
    local decoded_launch, launch_error = grok_launch.decode({profile_id = "window", brief = "", permission_mode = "default",
        gateway_tools = {"thread_read"}, gateway_hooks = {}})
    if not decoded_launch then error(tostring(launch_error)) end
    local launch_spec = grok_launch.specification(decoded_launch)
    launch_spec.home_ref = "session"
    launch_spec.working_directory_ref = "project"
    local gateway_file, gateway_error = grok_configuration.projection({endpoint = "127.0.0.1:4312",
        action_id = "grok-placement", tools = {"thread_read"}, hooks = {}, token_environment = "BEE_GATEWAY_TOKEN"})
    if not gateway_file then error(tostring(gateway_error)) end
    gateway_file.composition.base_path = base_path
    local value: types.LaunchRequest = {
        idempotency_key = fresh("grok-key"), owner_id = OWNER, owner_incarnation = 1,
        action_id = fresh("grok-action"), attempt_id = attempt_id,
        binding_ref = "bee.driver.grok.binding:binding", policy_ref = POLICY, profile_id = "window",
        binding_digest = DIGEST, profile_digest = DIGEST, launch = launch_spec,
        session_ref = session_ref,
        resources = {
            {name = "project", grant_ref = "grant-1", root_ref = ROOT, subpath = "", access = "write", purpose = "project"},
            {name = "session", grant_ref = "session-grant", root_ref = ROOT, subpath = "", access = "write", purpose = "session"},
        },
        environment = {}, environment_refs = {}, projections = {projection_id},
        required_cleanup = "direct_process", required_exit_observation = "eof_gated",
        timeouts = {stop_grace_ms = 500, drain_ms = 1000, retain_ms = 1000},
        delivery = {arguments = {}, files = {gateway_file}},
    }
    return value
end
local function intend_materialization(db, request: types.LaunchRequest)
    local digest, digest_error = request_codec.digest(request)
    if not digest then error(tostring(digest_error)) end
    local encoded, encode_error = json.encode(request)
    if not encoded then error(tostring(encode_error)) end
    local intended = store.intend(db, request, digest, encoded,
        {capability = "direct_process", exit_observation = "eof_gated"})
    if not intended.ok then error(tostring(intended.message)) end
end
local READONLY = "bee.placement.native:readonly_fixture"
local function admit_root(ref: string)
    local entry = registry.get(ref)
    if not entry then error("admitted roots entry") end
    local data = assert(bounds.object(entry.data))
    local roots = principals.objects(data.roots)
    data.roots = roots
    for _, root in ipairs(roots) do
        if root.root_ref == ROOT then return end
    end
    roots[#roots + 1] = {root_ref = ROOT, access = "write"}
    roots[#roots + 1] = {root_ref = READONLY, access = "read"}
    local changes = registry.snapshot():changes()
    changes:update(registry_input(entry))
    local applied, err = changes:apply()
    if not applied then error("admit root: " .. tostring(err)) end
end
local function activate_fixture_binding()
    local entry = registry.get("bee.harness.launch:harness_activation")
    if not entry then error("harness activation") end
    local data = assert(bounds.object(entry.data))
    local bindings = principals.items(data.bindings)
    data.bindings = bindings
    for _, binding in ipairs(bindings) do if binding == FIXTURE_BINDING then return end end
    bindings[#bindings + 1] = FIXTURE_BINDING
    local changes = registry.snapshot():changes()
    changes:update(registry_input(entry))
    local applied, err = changes:apply()
    if not applied then error("activate fixture binding: " .. tostring(err)) end
end
local function wait_for(predicate: () -> boolean, timeout_ms: integer): boolean
    local deadline = time.now():unix_nano() + timeout_ms * 1000000
    while time.now():unix_nano() < deadline do
        if predicate() then return true end
        time.sleep("50ms")
    end
    return predicate()
end
local function kinds(attempt_id: string): {string}
    local page = value(call(OWNER, "evidence", {attempt_id = attempt_id, limit = 64}))
    local list: {string} = {}
    for _, item in ipairs(principals.objects(page.evidence)) do list[#list + 1] = tostring(item.kind) end
    return list
end
local function alive(pid: string): boolean
    local executor = assert(exec.get("bee.placement.native.env:placement_executor"))
    local proc = assert(executor:exec("sh -c 'kill -0 " .. pid .. " 2>/dev/null && echo alive || echo gone'"))
    local stdout = proc:stdout_stream()
    assert(proc:start())
    local output = tostring(stdout:read(64) or "")
    proc:wait()
    stdout:close()
    executor:release()
    return output:find("alive", 1, true) ~= nil
end
local function shell(command: string): string
    local executor = assert(exec.get("bee.placement.native.env:placement_executor"))
    local proc = assert(executor:exec(quote.line({"sh", "-c", command})))
    local stdout = proc:stdout_stream()
    assert(proc:start())
    local output = ""
    while true do
        local chunk: unknown = stdout:read(4096)
        if type(chunk) ~= "string" or chunk == "" then break end
        output = output .. (chunk)
    end
    local code, err = proc:wait()
    stdout:close()
    executor:release()
    assert(code == 0, "fixture command exited " .. tostring(code) .. ": " .. tostring(err) .. ": " .. command)
    return output
end
local function fixture_home_file(home_path: string, relative: string): string
    local target = assert(homes.os_path(home_path .. "/home/" .. relative))
    return shell("cat " .. quote.posix(target))
end
local function has(list: {string}, wanted: string): boolean
    for _, item in ipairs(list) do
        if item == wanted then return true end
    end
    return false
end
local function suite(define_tests: () -> ())
    return function(options)
        local originals: {{[string]: unknown}} = {}
        for _, ref in ipairs({"bee.placement.native.env:placement_resource_mode", "bee.placement.native.env:placement_admitted_roots", "bee.resources.env:resource_roots", "bee.credentials.env:credential_sources", "bee.credentials.security:credential_file_policy", "bee.credentials.security:credential_file_write_policy", "bee.harness.launch:harness_activation", "bee.placement.native:codex_test_provider"}) do originals[#originals + 1] = assert(registry.get(ref)) end
        resource_mode("host_configured")
        admit_root("bee.placement.native.env:placement_admitted_roots")
        admit_root("bee.resources.env:resource_roots")
        activate_fixture_binding()
        local cases = test.run_cases(define_tests)
        local ok, result = pcall(cases, options)
        local changes = assert(registry.snapshot()):changes()
        for _, original in ipairs(originals) do changes:update(registry_input(original)) end
        assert(changes:apply())
        if not ok then error(tostring(result)) end
        return result
    end
end

return {
    registry_input = registry_input,
    fresh = fresh,
    caller = caller,
    credential_call = credential_call,
    admit_credential_source = admit_credential_source,
    admit_login_source = admit_login_source,
    admit_claude_login_source = admit_claude_login_source,
    admit_grok_login_source = admit_grok_login_source,
    resource_mode = resource_mode,
    resource_call = resource_call,
    call = call,
    value = value,
    attempt_of = attempt_of,
    await = await,
    launch = launch,
    await_retained_runner = await_retained_runner,
    provider_home_fixtures = provider_home_fixtures,
    provider_configuration = provider_configuration,
    update_codex_provider = update_codex_provider,
    provider_configuration_digest = provider_configuration_digest,
    retained_launch = retained_launch,
    grok_composition_request = grok_composition_request,
    intend_materialization = intend_materialization,
    wait_for = wait_for,
    kinds = kinds,
    alive = alive,
    shell = shell,
    fixture_home_file = fixture_home_file,
    has = has,
    CODEX_LOGIN_FORMAT = CODEX_LOGIN_FORMAT,
    CLAUDE_LOGIN_FORMAT = CLAUDE_LOGIN_FORMAT,
    OWNER = OWNER,
    DIGEST = DIGEST,
    ROOT = ROOT,
    POLICY = POLICY,
    NO_PROVIDER_POLICY = NO_PROVIDER_POLICY,
    SENTINEL = SENTINEL,
    READONLY = READONLY,
    suite = suite,
}
