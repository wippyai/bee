-- MIT. The gateway against the real harnesses through placement: the
-- version-recorded Claude Code and Codex executables launch under a policy
-- that admits gateway tools, find the host-approved configuration in
-- their private home, expand the environment reference into the token
-- the runner materialized, initialize, discover the tools and read the
-- bound thread through the actual gateway when a scripted loopback model
-- endpoint calls for it. Without the variable neither harness
-- authenticates anything: the credential is never presented. Executable
-- and configuration measurements are on record, and no token reaches
-- evidence, records, output or the endpoint. Without an executable the
-- gate is reported open.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local process = require("process")
local registry = require("registry")
local env = require("env")
local time = require("time")
local channel = require("channel")
local json = require("json")
local exec = require("exec")
local base64 = require("base64")
local catalog = require("catalog")
local policy = require("policy")
local claude_launch = require("claude_launch")
local codex_launch = require("codex_launch")
local codex_configuration = require("codex_configuration")
local configuration = require("configuration")
local placement_fixture = require("placement_fixture")
local quote = require("quote")
local ACTOR = "bee.test.gateway_harness"
local CLAUDE_POLICY = "bee.harness.catalog:claude_gateway_policy"
local CODEX_POLICY = "bee.harness.catalog:codex_gateway_policy"
local PROVIDER = "bee.harness.catalog:codex_fixture_provider"
local CLAUDE_SOURCE = "bee.harness.catalog:claude_sentinel_key"
local CODEX_SOURCE = "bee.harness.catalog:codex_sentinel_key"
local ROOT = "bee.harness.catalog:project_fixture"
local CLAUDE_BINDING = "bee.driver.claude:binding"
local CODEX_BINDING = "bee.driver.codex:binding"
local CLAUDE_SENTINEL = "sk-ant-sentinel-bee-000"
local CODEX_SENTINEL = "sk-sentinel-bee-000"
local GATEWAY_TOKEN = "BEE_GATEWAY_TOKEN"
local HOOK_TOKEN = "BEE_GATEWAY_HOOK_TOKEN"
type Object = {[string]: unknown}
type Outcome = {value: Object?, error: string?}
local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end
local scope_names = {"bee.harness.catalog:carrier_client_policy", "bee.harness.catalog:gateway_client_policy", "bee:thread_create_policy", "bee:thread_observe_policy", "bee:thread_lifecycle_policy",
    "bee:thread_carrier_policy", "bee:carrier_policy", "bee.harness.catalog:carrier_spawn_policy", "bee.harness.catalog:codex_credential_client_policy", "bee:credential_manage_policy", "bee:credential_issue_policy",
    "bee:gateway_manage_policy", "bee:gateway_admit_policy", "bee:gateway_materialize_policy"}
local function scope(): security.Scope
    local policies: {security.Policy} = {}
    for index, name in ipairs(scope_names) do
        local found, err = security.policy(name)
        if err or not found then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = found
    end
    return security.new_scope(policies)
end
local actor = security.new_actor(ACTOR)
local function call(target: string, request: unknown): Object
    local result, err = funcs.new():with_actor(actor):with_scope(scope()):call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    local reply = result :: {ok: boolean, error: {code: string, message: string}?, value: unknown}
    if not reply.ok then error(target .. ": " .. tostring(reply.error and reply.error.code) .. ": " .. tostring(reply.error and reply.error.message)) end
    return reply.value :: Object
end
local function read_all(stream): string
    local content = ""
    while true do
        local chunk: unknown = stream:read(65536)
        if type(chunk) ~= "string" or chunk == "" then break end
        content = content .. (chunk :: string)
    end
    return content
end
local function shell(command: string, environment: {[string]: string}?): string
    local executor = assert(exec.get("bee.placement.native:executor"))
    local proc, exec_error = executor:exec("sh -c '" .. command .. "'", {env = environment or {}})
    if not proc then error("exec " .. command .. ": " .. tostring(exec_error)) end
    local stdout = proc:stdout_stream()
    local started, start_error = proc:start()
    if not started then error("start " .. command .. ": " .. tostring(start_error)) end
    local output = read_all(stdout)
    proc:wait()
    stdout:close()
    executor:release()
    return output
end
-- Writes exact bytes to a path without shell interpretation of the content.
local function write_file(path: string, content: string)
    local encoded = assert(base64.encode(content))
    shell('python3 -c "import sys, base64, pathlib; pathlib.Path(sys.argv[1]).write_bytes(base64.b64decode(sys.argv[2]))" ' .. path .. " " .. encoded)
end
local function apply(entry: Object)
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("apply " .. tostring(entry.id) .. ": " .. tostring(err)) end
end
local function admit(entry_id: string, list_key: string, item: Object, matches: (Object) -> boolean)
    local entry = registry.get(entry_id)
    if not entry then error(entry_id) end
    local list = (entry.data :: Object)[list_key] :: {Object}
    for _, existing in ipairs(list) do
        if matches(existing) then return end
    end
    list[#list + 1] = item
    apply(entry)
end
local function binary(name: string): string?
    local bin, err = env.get("bee.harness.catalog:" .. name)
    if err or type(bin) ~= "string" or bin == "" then return nil end
    return bin
end
local function fixture_bin(): string
    local bin, err = env.get("bee.harness.catalog:fixture_bin")
    if err or type(bin) ~= "string" or bin == "" then error("BEE_FIXTURE_BIN is not set for the test runtime") end
    return bin
end
local endpoint_handle: any = nil
local endpoint_executor: any = nil
-- The endpoint scripts one call of the named gateway tool, then text.
local function start_endpoint(record: string): string
    local executor = assert(exec.get("bee.placement.native:executor"))
    local proc, err = executor:exec(fixture_bin() .. "/endpoint " .. record, {env = {BEE_ENDPOINT_MCP_TOOL = "thread_read"}})
    if not proc then error("endpoint: " .. tostring(err)) end
    local started, start_error = proc:start()
    if not started then error("start endpoint: " .. tostring(start_error)) end
    endpoint_handle, endpoint_executor = proc, executor
    for _ = 1, 100 do
        local port = shell("cat " .. record .. ".port 2>/dev/null"):match("%d+")
        if port then return port end
        time.sleep("50ms")
    end
    error("the endpoint did not report its port")
end
local function stop_endpoint()
    if endpoint_handle then
        endpoint_handle:signal(9)
        endpoint_handle:wait()
        endpoint_handle:close(true)
    end
    if endpoint_executor then endpoint_executor:release() end
    endpoint_handle, endpoint_executor = nil, nil
end
local function measured(binding_ref: string, policy_ref: string): (string, string, string)
    local snapshot = assert(catalog.snapshot())
    local usable = assert(catalog.usable(snapshot))
    for _, candidate in ipairs(usable) do
        if candidate.binding_id == binding_ref then
            local pinned, policy_error = policy.load(policy_ref)
            if not pinned then error(tostring(policy_error)) end
            return tostring(candidate.binding_digest.entry), tostring(candidate.profile_digest.entry), tostring(pinned.digest)
        end
    end
    error("binding " .. binding_ref .. " is not usable on this host")
end
local function endpoint_address(): string
    local entry = registry.get("bee:gateway_endpoint")
    if not entry then error("gateway endpoint entry") end
    return tostring((entry.data :: Object).address)
end
local function gateway_input(address: string, action_id: string, hooks: {string}?): configuration.GatewayInput
    return {endpoint = address, action_id = action_id, tools = {"thread_read", "thread_wait"}, hooks = hooks or {},
        token_environment = GATEWAY_TOKEN, hook_token_environment = hooks and #hooks > 0 and HOOK_TOKEN or nil}
end
local function codex_gateway(input: configuration.GatewayInput): codex_configuration.Gateway
    return {endpoint = input.endpoint, action_id = input.action_id, tools = input.tools, hooks = input.hooks,
        token_environment = input.token_environment, hook_token_environment = input.hook_token_environment}
end
local function claude_delivery(input: configuration.GatewayInput): configuration.Delivery
    local delivery, delivery_error = configuration.call("bee.driver.claude:configure", {fixture = false, gateway = input})
    if not delivery then error(tostring(delivery_error)) end
    return delivery
end
local function append_delivery(argv: {string}, delivery: configuration.Delivery)
    for _, item in ipairs(delivery.arguments) do argv[#argv + 1] = item end
end
local function open_gateway()
    call("bee.gateway:open", {address = endpoint_address()})
end
local function thread(): string
    local created = call("bee.threads.service:create", {thread_id = fresh("thread"), idempotency_key = fresh("key"), title = "Gateway harness"})
    return created.thread_id :: string
end
local function projection_for(workspace: string, attempt_id: string, name: string, provider: string, source: string, binding_ref: string, policy_ref: string): string
    call("bee.credentials:define", {workspace_id = workspace, name = name, provider = provider, source = {kind = "env_variable", ref = source}})
    local binding_digest, profile_digest, policy_digest = measured(binding_ref, policy_ref)
    local issued = call("bee.credentials:issue_projection", {workspace_id = workspace, name = name, audience = ACTOR, attempt_id = attempt_id, profile_id = "batch",
        profile_digest = profile_digest, binding_digest = binding_digest, launch_policy_digest = policy_digest, idempotency_key = fresh("key")})
    return issued.projection_id :: string
end
local function request(thread_id: string, attempt_id: string, binding_ref: string, policy_ref: string, projections: {string}): Object
    local placement = placement_fixture.resolve()
    return {thread_id = thread_id, action_id = "action-" .. attempt_id, attempt_id = attempt_id, owner_id = ACTOR, owner_incarnation = 1, binding_ref = binding_ref,
        profile_id = "batch", brief = "read the thread", policy_ref = policy_ref, resources = {{name = "project", grant_ref = "host", root_ref = ROOT, subpath = "", access = "write", purpose = "project"}},
        environment = {PATH = "/usr/bin:/bin"}, working_directory = "project", projections = projections, placement_binding_ref = placement.binding_id,
        placement_binding_digest = placement.binding_digest}
end
local function spawn_carrier(request_value: Object): string
    local spawner = process.with_context({}):with_actor(actor):with_scope(scope())
    local pid, err = spawner:spawn_monitored("bee.harness.carrier:process", "bee:workers", request_value, "open", process.pid())
    if not pid then error("spawn carrier: " .. tostring(err)) end
    return tostring(pid)
end
local exited: {[string]: Outcome} = {}
local function await_carrier(pid: string, label: string): Outcome
    local events = assert(process.events())
    local deadline = time.after("180s")
    while not exited[pid] do
        local selected = channel.select({events:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then error(label .. " did not finish") end
        local event = selected.value
        if event.kind == process.event.EXIT then
            local result = event.result or {}
            local value: Object? = nil
            if type(result.value) == "table" then value = result.value :: Object end
            exited[tostring(event.from)] = {value = value, error = result.error and tostring(result.error) or nil}
        end
    end
    return exited[pid] :: Outcome
end
local function records_of(thread_id: string): {Object}
    local all: {Object} = {}
    local cursor = 0
    for _ = 1, 32 do
        local page = call("bee.threads.service:read_after", {thread_id = thread_id, cursor = cursor, limit = 64})
        for _, item in ipairs(page.records :: {Object}) do all[#all + 1] = item end
        if page.has_more ~= true then break end
        cursor = math.floor(page.scanned_through :: number)
    end
    return all
end
local function evidence_of(attempt_id: string): {Object}
    local page = call("bee.placement.native:evidence", {attempt_id = attempt_id, limit = 64})
    return page.evidence :: {Object}
end
-- The stream as the carrier recorded it, for a failure message.
local function stream_summary(thread_id: string): string
    local lines: {string} = {}
    for _, item in ipairs(records_of(thread_id)) do
        if item.kind == "observation" and item.source == "stream" then
            local data = (item.body :: Object).data :: Object
            local text = ""
            if type(data.content) == "table" then text = tostring((data.content :: Object).text or "") end
            lines[#lines + 1] = tostring(data.type) .. "/" .. tostring(data.code or data.phase or data.name or "") .. ":" .. text:sub(1, 160)
        end
    end
    return table.concat(lines, " | ")
end
local function kinds_of(evidence: {Object}): {string}
    local list: {string} = {}
    for index, item in ipairs(evidence) do list[index] = tostring(item.kind) end
    return list
end
local function has(list: {string}, wanted: string): boolean
    for _, item in ipairs(list) do
        if item == wanted then return true end
    end
    return false
end
-- No bearer value other than the environment reference, no destination
-- assignment, and no sentinel key anywhere a token or key could leak.
local function leak_free(text: string, label: string, sentinel_allowed: boolean?)
    for bearer in text:gmatch("Bearer%s+([^%s\\\"]+)") do
        local sentinel = bearer == CLAUDE_SENTINEL or bearer == CODEX_SENTINEL
        if bearer ~= "${" .. GATEWAY_TOKEN .. "}" and not (sentinel_allowed and sentinel) then error(label .. " carries a bearer value") end
    end
    if text:find(GATEWAY_TOKEN .. "=", 1, true) then error(label .. " carries the token destination assignment") end
    if not sentinel_allowed and (text:find(CLAUDE_SENTINEL, 1, true) or text:find(CODEX_SENTINEL, 1, true)) then error(label .. " carries a sentinel key") end
end
type Harness = {name: string, bin: string, binding: string, policy: string, source: string, provider: string, credential: string, sentinel: string}
-- The host side for one harness: the executable bound in the policy, the
-- loopback model endpoint selected by the host, the root and the sentinel
-- source admitted. The gateway endpoint is the composition's own.
local function prepare_host(harness: Harness, port: string)
    local entry = registry.get(harness.policy)
    if not entry then error(harness.policy) end
    local data = entry.data :: Object
    data.executables = {[harness.name] = harness.bin}
    if harness.name == "claude" then data.environment = {ANTHROPIC_BASE_URL = "http://127.0.0.1:" .. port} end
    apply(entry)
    if harness.name == "codex" then
        local provider = registry.get(PROVIDER)
        if not provider then error("provider entry") end
        (provider.data :: Object).base_url = "http://127.0.0.1:" .. port .. "/v1"
        apply(provider)
    end
    admit("bee.placement.native:admitted_roots", "roots", {root_ref = ROOT, access = "write"}, function(item: Object): boolean return item.root_ref == ROOT end)
    -- The source is admitted for this suite's audience; other suites admit
    -- the same source for theirs.
    admit("bee:credential_sources", "sources", {ref = harness.source, workspace_id = "*", audience = ACTOR, provider = harness.provider, projection_kinds = {"environment"}}, function(item: Object): boolean return item.ref == harness.source and item.audience == ACTOR end)
end
local function through_placement(harness: Harness)
    local root = ".wippy/gateway-" .. harness.name .. "-" .. fresh("run")
    shell("mkdir -p " .. root)
    local record = root .. "/endpoint.jsonl"
    local port = start_endpoint(record)
    prepare_host(harness, port)
    open_gateway()
    local workspace = fresh("ws")
    local thread_id, attempt_id = thread(), fresh("attempt")
    local projection_id = projection_for(workspace, attempt_id, harness.credential, harness.provider, harness.source, harness.binding, harness.policy)
    local outcome = await_carrier(spawn_carrier(request(thread_id, attempt_id, harness.binding, harness.policy, {projection_id})), harness.name .. " run")
    stop_endpoint()
    if not outcome.value then error(harness.name .. " run failed: " .. tostring(outcome.error)) end
    local settlement = outcome.value.settlement :: Object
    local recorded = shell("cat " .. record)
    local evidence = evidence_of(attempt_id)
    local kinds = kinds_of(evidence)
    -- Discovery: the endpoint was offered the gateway tools by the harness.
    if not recorded:find('"mcp_tools": ["thread_read", "thread_wait"]', 1, true) and not recorded:find('"mcp_tools": ["thread_wait", "thread_read"]', 1, true) then
        error(harness.name .. ": the endpoint saw no gateway tools: [" .. recorded:sub(1, 600) .. "]; settlement " .. tostring(settlement.outcome) .. " " .. tostring(settlement.reason) .. "; evidence " .. table.concat(kinds, ","))
    end
    -- The read: the harness called thread_read through the gateway and
    -- handed the owner's page, its records included, back to the model.
    if not recorded:find('"tool_result": true', 1, true) or not recorded:find('\\"records\\":[', 1, true) then
        local details: {string} = {}
        for index, item in ipairs(evidence) do details[index] = tostring(item.kind) .. "=" .. tostring(item.detail):sub(1, 120) end
        error(harness.name .. ": no thread read came back through the gateway: [" .. recorded:sub(1, 1500) .. "]; stream: " .. stream_summary(thread_id):sub(1, 2000) .. "; evidence: " .. table.concat(details, " ; "))
    end
    test.eq(settlement.outcome, "succeeded")
    -- The credential was presented for initialization, discovery and the call.
    local checked = call("bee.gateway:check", {attempt_id = attempt_id, carrier_epoch = 1})
    if (tonumber(checked.presented_count) or 0) < 3 then error(harness.name .. ": the credential was presented " .. tostring(checked.presented_count) .. " times") end
    -- The hooks the harness reported reached the thread as records through
    -- the carrier, with nothing content bearing in them.
    local hook_events: {[string]: integer} = {}
    local hook_text = ""
    for _, item in ipairs(records_of(thread_id)) do
        if item.kind == "observation" and item.source == "bee" then
            local data = (item.body :: Object).data :: Object
            if data.event_name == "bee.harness.hook" then
                local payload = json.decode(tostring(data.payload_json)) :: Object
                hook_events[tostring(payload.event)] = (hook_events[tostring(payload.event)] or 0) + 1
                hook_text = hook_text .. tostring(data.payload_json)
            end
        end
    end
    local expected_hooks = harness.name == "claude" and {"UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"} or {"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"}
    for _, event in ipairs(expected_hooks) do
        if not hook_events[event] then error(harness.name .. ": hook " .. event .. " never became a record; got " .. tostring(json.encode(hook_events))) end
    end
    test.is_nil(hook_text:find("read the thread", 1, true))
    test.is_nil(hook_text:find("cursor", 1, true))
    leak_free(hook_text, harness.name .. " hook records")
    test.eq(checked.valid, false)
    test.eq(checked.reason, "binding is revoked")
    -- Measurements and the projection are on record; nothing leaks. The
    -- executable measurement is asserted when this runtime can measure the
    -- executable where it is installed; under the fixture policy a launch
    -- proceeds without one otherwise.
    local wanted_evidence = {"gateway.materialized", "credential.materialized"}
    local capabilities = call("bee.placement.native:capabilities", {})
    if (capabilities.executable_measurement :: Object).streaming == true then
        local measurable, measure_err = funcs.new():with_actor(actor):with_scope(scope()):call("bee.placement.native:measure_executable", {path = harness.bin})
        if measure_err or type(measurable) ~= "table" or (measurable :: Object).ok ~= true then error(harness.name .. ": this runtime measures streams but could not measure " .. harness.bin .. ": " .. tostring(measure_err or json.encode(measurable))) end
        wanted_evidence[#wanted_evidence + 1] = "executable.measured"
    end
    for _, wanted in ipairs(wanted_evidence) do
        if not has(kinds, wanted) then error(harness.name .. ": evidence " .. wanted .. " missing in " .. table.concat(kinds, ",")) end
    end
    if harness.name == "codex" and not has(kinds, "configuration.materialized") then error("codex: configuration.materialized missing in " .. table.concat(kinds, ",")) end
    for _, item in ipairs(evidence) do leak_free(json.encode(item), harness.name .. " evidence") end
    for _, item in ipairs(records_of(thread_id)) do leak_free(json.encode(item), harness.name .. " record") end
    leak_free(json.encode(outcome.value), harness.name .. " outcome")
    -- The model endpoint records the sentinel key it was sent by design;
    -- the gateway token must not be there.
    leak_free(recorded, harness.name .. " endpoint record", true)
    shell("rm -rf " .. root)
end
-- The harness run directly with the same host-approved configuration and
-- no token variable: the bearer reference stays unexpanded (Claude Code)
-- or no credential resolves (Codex), the gateway refuses, and the
-- credential is never presented.
local function without_variable(harness: Harness)
    local root = ".wippy/gateway-" .. harness.name .. "-novar-" .. fresh("run")
    shell("mkdir -p " .. root .. "/home/.codex " .. root .. "/work")
    local record = root .. "/endpoint.jsonl"
    local port = start_endpoint(record)
    open_gateway()
    local attempt_id = fresh("direct")
    local action_id = "action-" .. attempt_id
    local admitted = call("bee.gateway:admit", {subject = ACTOR, action_id = action_id, attempt_id = attempt_id, thread_id = thread(), owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read", "thread_wait"}})
    local binding_id = tostring((admitted.binding :: Object).binding_id)
    local address = endpoint_address()
    local home = shell("cd " .. root .. "/home && pwd"):gsub("%s+$", "")
    local argv: {string} = {}
    local environment: {[string]: string} = {PATH = "/usr/bin:/bin", HOME = home}
    local stdin: string? = nil
    if harness.name == "claude" then
        local delivery = claude_delivery(gateway_input(address, action_id, nil))
        local decoded, decode_error = claude_launch.decode({profile_id = "batch", brief = "read the thread", permission_mode = "dontAsk", max_turns = 3, gateway_tools = {"thread_read", "thread_wait"}})
        if not decoded then error(decode_error or "Claude launch request missing") end
        local specification = claude_launch.specification(decoded)
        argv[1] = harness.bin
        append_delivery(argv, delivery)
        for _, item in ipairs(specification.argv) do argv[#argv + 1] = item end
        environment.ANTHROPIC_API_KEY = CLAUDE_SENTINEL
        environment.ANTHROPIC_BASE_URL = "http://127.0.0.1:" .. port
    else
        local provider_entry = registry.get(PROVIDER)
        if not provider_entry then error("provider entry") end
        (provider_entry.data :: Object).base_url = "http://127.0.0.1:" .. port .. "/v1"
        local provider, provider_error = codex_configuration.decode(PROVIDER, provider_entry :: {[string]: unknown})
        if not provider then error(provider_error or "Codex provider missing") end
        local content = codex_configuration.render(provider, codex_configuration.gateway_section(codex_gateway(gateway_input(address, action_id, nil))))
        write_file(root .. "/home/.codex/config.toml", content)
        local decoded, decode_error = codex_launch.decode({profile_id = "batch", brief = "read the thread", sandbox = "read-only", gateway_tools = {"thread_read", "thread_wait"}})
        if not decoded then error(decode_error or "Codex launch request missing") end
        local specification = codex_launch.specification(decoded)
        argv[1] = harness.bin
        for _, item in ipairs(specification.argv) do argv[#argv + 1] = item end
        stdin = specification.stdin
        environment.CODEX_HOME = home .. "/.codex"
        environment.OPENAI_API_KEY = CODEX_SENTINEL
    end
    local executor = assert(exec.get("bee.placement.native:executor"))
    local proc, proc_error = executor:exec(quote.line(argv), {work_dir = root .. "/work", env = environment})
    if not proc then error("exec " .. harness.name .. ": " .. tostring(proc_error)) end
    local stdout = proc:stdout_stream()
    local stderr = proc:stderr_stream()
    local started, start_error = proc:start()
    if not started then error("start " .. harness.name .. ": " .. tostring(start_error)) end
    if stdin then
        local written, write_error = proc:write_stdin(stdin)
        if not written then error("write the brief: " .. tostring(write_error)) end
        local handle = proc :: {[string]: unknown}
        if type(handle.close_stdin) == "function" then (handle.close_stdin :: (unknown) -> unknown)(proc) end
    end
    local output = read_all(stdout)
    local errors = read_all(stderr)
    local exit_code = proc:wait()
    stdout:close()
    stderr:close()
    executor:release()
    stop_endpoint()
    local recorded = shell("cat " .. record)
    if not recorded:find('"path": "/v1/', 1, true) then
        error(harness.name .. " did not reach the model endpoint; exit " .. tostring(exit_code) .. "; command " .. quote.line(argv) .. "; home " .. shell("ls -la " .. root .. "/home; cat " .. root .. "/home/.claude.json 2>/dev/null"):sub(1, 500) .. "; stdout: " .. output:sub(1, 600) .. "; stderr: " .. errors:sub(1, 600))
    end
    local checked = call("bee.gateway:check", {binding_id = binding_id})
    test.eq(tonumber(checked.presented_count), 0)
    test.eq(checked.credential_generation, 0)
    if recorded:find('\\"records\\":[', 1, true) then error(harness.name .. " without the variable read the thread: [" .. recorded:sub(1, 600) .. "]") end
    if harness.name == "claude" then
        if not output:find('"name":"bee","status":"failed"', 1, true) then error("claude reported no failed gateway server; stdout: " .. output:sub(1, 600) .. "; stderr: " .. errors:sub(1, 600)) end
    else
        if recorded:find('"mcp_tools": ["thread', 1, true) then error("codex offered gateway tools without a credential: " .. recorded:sub(1, 600)) end
    end
    leak_free(output, harness.name .. " output")
    leak_free(errors, harness.name .. " stderr")
    call("bee.gateway:revoke", {binding_id = binding_id})
    shell("rm -rf " .. root)
end
-- The hook adapters against the actual gateway: the harness runs directly
-- with the host-approved MCP configuration and the host-generated hook
-- configuration, both credentials materialized in-test, and reports its
-- hooks to /hook/{action}; the gateway queues allowlisted fields only and
-- answers nothing a harness could act on, so the turn completes as before.
local function drive_app_server(codex_home: string, cwd: string): {[string]: string}
    -- The pinned executable's own hook listing is the trust authority: its
    -- app-server answers hooks/list with each hook's key and current hash.
    local executor = assert(exec.get("bee.placement.native:executor"))
    local proc, err = executor:exec("codex app-server", {env = {PATH = "/usr/bin:/bin", HOME = codex_home:gsub("/%.codex$", ""), CODEX_HOME = codex_home}})
    if not proc then error("exec codex app-server: " .. tostring(err)) end
    local stdout = proc:stdout_stream()
    assert(proc:start())
    for _, line in ipairs({json.encode({jsonrpc = "2.0", id = 1, method = "initialize", params = {clientInfo = {name = "bee", title = "bee", version = "0"}}}),
        json.encode({jsonrpc = "2.0", method = "initialized"}), json.encode({jsonrpc = "2.0", id = 2, method = "hooks/list", params = {cwds = {cwd}}})}) do
        assert(proc:write_stdin(tostring(line) .. "\n"))
    end
    local hashes: {[string]: string} = {}
    local buffer = ""
    local deadline = time.now():add(20 * 1000000000)
    while time.now():before(deadline) do
        local chunk: unknown = stdout:read(4096)
        if type(chunk) ~= "string" or chunk == "" then break end
        buffer = buffer .. (chunk :: string)
        local finished = false
        for line in buffer:gmatch("[^\n]+") do
            local decoded: unknown = json.decode(line)
            if type(decoded) == "table" and (decoded :: Object).id == 2 then
                local data = ((decoded :: Object).result :: Object).data :: {Object}
                for _, entry in ipairs(data) do
                    for _, hook in ipairs(entry.hooks :: {Object}) do hashes[tostring(hook.key)] = tostring(hook.currentHash) end
                end
                finished = true
            end
        end
        if finished then break end
    end
    proc:signal(9)
    proc:wait()
    stdout:close()
    executor:release()
    if next(hashes) == nil then error("codex app-server listed no hooks") end
    return hashes
end
local HOOK_EVENTS = {"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"}
local function hooks_through_gateway(harness: Harness)
    local root = ".wippy/gateway-" .. harness.name .. "-hooks-" .. fresh("run")
    shell("mkdir -p " .. root .. "/home/.codex " .. root .. "/home/.claude " .. root .. "/work")
    local record = root .. "/endpoint.jsonl"
    local port = start_endpoint(record)
    open_gateway()
    local attempt_id = fresh("direct")
    local action_id = "action-" .. attempt_id
    local admitted = call("bee.gateway:admit", {subject = ACTOR, action_id = action_id, attempt_id = attempt_id, thread_id = thread(), owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read", "thread_wait"}, hooks = HOOK_EVENTS})
    local binding_id = tostring((admitted.binding :: Object).binding_id)
    local authorized = call("bee.gateway:authorize_materialization", {attempt_id = attempt_id, carrier_epoch = 1, binding_id = binding_id})
    local minted = call("bee.gateway:materialize", {attempt_id = attempt_id, carrier_epoch = 1, binding_id = binding_id, materialization_key = authorized.materialization_key})
    local address = endpoint_address()
    local home = shell("cd " .. root .. "/home && pwd"):gsub("%s+$", "")
    local work = shell("cd " .. root .. "/work && pwd"):gsub("%s+$", "")
    local argv: {string} = {}
    local environment: {[string]: string} = {PATH = "/usr/bin:/bin", HOME = home, BEE_GATEWAY_TOKEN = tostring(minted.token), BEE_GATEWAY_HOOK_TOKEN = tostring(minted.hook_token)}
    local stdin: string? = nil
    if harness.name == "claude" then
        local delivery = claude_delivery(gateway_input(address, action_id, HOOK_EVENTS))
        local decoded, decode_error = claude_launch.decode({profile_id = "batch", brief = "read the thread", permission_mode = "dontAsk", max_turns = 3, gateway_tools = {"thread_read", "thread_wait"}})
        if not decoded then error(tostring(decode_error)) end
        local specification = claude_launch.specification(decoded)
        argv[1] = harness.bin
        append_delivery(argv, delivery)
        for _, item in ipairs(specification.argv) do argv[#argv + 1] = item end
        environment.ANTHROPIC_API_KEY = CLAUDE_SENTINEL
        environment.ANTHROPIC_BASE_URL = "http://127.0.0.1:" .. port
    else
        local provider_entry = registry.get(PROVIDER)
        if not provider_entry then error("provider entry") end
        (provider_entry.data :: Object).base_url = "http://127.0.0.1:" .. port .. "/v1"
        local provider, provider_error = codex_configuration.decode(PROVIDER, provider_entry :: {[string]: unknown})
        if not provider then error(tostring(provider_error)) end
        local input = gateway_input(address, action_id, HOOK_EVENTS)
        local codex_input = codex_gateway(input)
        local content = codex_configuration.render(provider, codex_configuration.gateway_section(codex_input))
        write_file(root .. "/home/.codex/config.toml", content)
        local files, files_error = codex_configuration.hook_files(codex_input, home)
        if not files then error(tostring(files_error)) end
        for _, file in ipairs(files) do write_file(root .. "/home/" .. file.path, file.content) end
        local hashes = drive_app_server(home .. "/.codex", work)
        if next(hashes) == nil then error("codex app-server listed no generated hooks") end
        local decoded, decode_error = codex_launch.decode({profile_id = "batch", brief = "read the thread", sandbox = "read-only", gateway_tools = {"thread_read", "thread_wait"}, gateway_hooks = HOOK_EVENTS})
        if not decoded then error(tostring(decode_error)) end
        local specification = codex_launch.specification(decoded)
        argv[1] = harness.bin
        for _, item in ipairs(specification.argv) do argv[#argv + 1] = item end
        stdin = specification.stdin
        environment.CODEX_HOME = home .. "/.codex"
        environment.OPENAI_API_KEY = CODEX_SENTINEL
    end
    local executor = assert(exec.get("bee.placement.native:executor"))
    local started_at = time.now()
    local proc, proc_error = executor:exec(quote.line(argv), {work_dir = work, env = environment})
    if not proc then error("exec " .. harness.name .. ": " .. tostring(proc_error)) end
    local stdout = proc:stdout_stream()
    local stderr = proc:stderr_stream()
    assert(proc:start())
    if stdin then
        assert(proc:write_stdin(stdin))
        local handle = proc :: {[string]: unknown}
        if type(handle.close_stdin) == "function" then (handle.close_stdin :: (unknown) -> unknown)(proc) end
    end
    local output = read_all(stdout)
    local errors = read_all(stderr)
    proc:wait()
    stdout:close()
    stderr:close()
    executor:release()
    local elapsed_ms = time.now():sub(started_at):milliseconds()
    stop_endpoint()
    local recorded = shell("cat " .. record)
    if not recorded:find('"tool_result": true', 1, true) then error(harness.name .. " with hooks did not complete the read: [" .. recorded:sub(1, 600) .. "]; stdout " .. output:sub(1, 400) .. "; stderr " .. errors:sub(1, 400)) end
    local queue = call("bee.gateway:hook_queue", {binding_id = binding_id})
    local seen: {[string]: Object} = {}
    for _, item in ipairs(queue.hooks :: {Object}) do seen[tostring(item.event)] = item end
    local expected = harness.name == "claude" and {"UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"} or {"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"}
    for _, event in ipairs(expected) do
        if not seen[event] then error(harness.name .. ": hook " .. event .. " never reached the gateway; queue " .. tostring(json.encode(queue.hooks)):sub(1, 800) .. "; stderr " .. errors:sub(1, 400)) end
    end
    local provenance = harness.name == "claude" and "http" or "codex:hook_engine"
    for _, item in ipairs(queue.hooks :: {Object}) do
        test.eq(item.provenance, provenance)
        test.eq(item.status, "queued")
        -- A stop names no occurrence of its own; every other event does.
        test.eq(item.ambiguous, item.event == "Stop")
    end
    local pre = seen.PreToolUse.fields :: Object
    test.eq(pre.tool_name, "mcp__bee__thread_read")
    test.is_nil(pre.tool_input)
    test.is_true((tonumber((pre.content_sizes :: Object).tool_input) or 0) > 0)
    local queue_text = json.encode(queue.hooks) or ""
    test.is_nil(queue_text:find("read the thread", 1, true))
    test.is_nil(queue_text:find("cursor", 1, true))
    leak_free(queue_text, harness.name .. " hook queue")
    leak_free(output, harness.name .. " output")
    leak_free(errors, harness.name .. " stderr")
    -- Five hooks bounded at two seconds each cannot have delayed the turn
    -- past the budget a slow gateway would cost; the gateway answered at once.
    test.is_true(elapsed_ms < 30000)
    local checked = call("bee.gateway:check", {binding_id = binding_id})
    test.is_true((tonumber(checked.presented_count) or 0) >= 3)
    call("bee.gateway:revoke", {binding_id = binding_id})
    shell("rm -rf " .. root)
end
local HARNESSES: {Harness} = {
    {name = "claude", bin = "", binding = CLAUDE_BINDING, policy = CLAUDE_POLICY, source = CLAUDE_SOURCE, provider = "claude", credential = "anthropic", sentinel = CLAUDE_SENTINEL},
    {name = "codex", bin = "", binding = CODEX_BINDING, policy = CODEX_POLICY, source = CODEX_SOURCE, provider = "codex", credential = "openai", sentinel = CODEX_SENTINEL},
}
-- Codex reads its brief until end of file, so both Codex proofs need a
-- runtime that can close a child's stdin. With a configured Codex executable
-- the dedicated managed-launch gate requires that capability.
local function ready_for(harness: Harness): boolean
    local bin = binary(harness.name .. "_bin")
    if not bin then return false end
    -- The policy binds the installed image itself, never a link to it:
    -- measurement opens the path inside the host volume, which follows no
    -- links out of it.
    harness.bin = shell("readlink -f " .. bin):gsub("%s+$", "")
    if harness.name == "codex" then
        local capabilities = call("bee.placement.native:capabilities", {})
        if capabilities.stdin_close ~= true then
            error("the configured Codex executable requires placement stdin_close")
        end
    end
    return true
end
local function define_tests()
    test.describe("Gateway through the real harnesses", function()
        for _, harness in ipairs(HARNESSES) do
            local title = harness.name == "claude" and "Claude Code" or "Codex"
            test.it(title .. " initializes, discovers and reads the bound thread through the gateway, or reports the gate open", function()
                if not ready_for(harness) then return end
                through_placement(harness)
            end)
            test.it(title .. " without the token variable authenticates nothing, or reports the gate open", function()
                if not ready_for(harness) then return end
                without_variable(harness)
            end)
            test.it(title .. " reports its hooks to the gateway under the hook credential and the turn completes, or reports the gate open", function()
                if not ready_for(harness) then return end
                hooks_through_gateway(harness)
            end)
        end
    end)
end
return test.run_cases(define_tests)
