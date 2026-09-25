-- MIT. API-key authentication-path selection for Claude, settings-free and
-- environment-only, through the real placement runner: the driver-prepared
-- launch, the broker-projected sentinel ANTHROPIC_API_KEY, the host-selected
-- loopback endpoint in the policy environment, an isolated private home
-- with no login state, and the version-recorded pinned executable. The
-- endpoint answers 400, so a passing run proves path selection only, never
-- provider acceptance or a completed turn. Without the executable the gate
-- is reported open.
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
local catalog = require("catalog")
local policy = require("policy")
local launch = require("launch")
local placement_fixture = require("placement_fixture")
local ACTOR = "bee.test.claude_carrier"
local POLICY = "bee.harness.catalog:claude_auth_fixture_policy"
local SOURCE = "bee.harness.catalog:claude_sentinel_key"
local ROOT = "bee.harness.catalog:project_fixture"
local BINDING = "bee.driver.claude:binding"
local SENTINEL = "sk-ant-sentinel-bee-000"
type Object = {[string]: unknown}
type Outcome = {value: Object?, error: string?}
local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end
local scope_names = {"bee.harness.catalog:carrier_client_policy", "bee.security.threads:thread_create_policy", "bee.security.threads:thread_observe_policy", "bee.security.threads:thread_lifecycle_policy",
    "bee.security.threads:thread_carrier_policy", "bee.security.harness:carrier_policy", "bee.harness.catalog:carrier_spawn_policy", "bee.harness.catalog:codex_credential_client_policy", "bee.security.credentials:credential_manage_policy", "bee.security.credentials:credential_issue_policy"}
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
local function shell(command: string): string
    local executor = assert(exec.get("bee.placement.native:executor"))
    local proc, exec_error = executor:exec("sh -c '" .. command .. "'")
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
local function claude_bin(): string?
    local bin, err = env.get("bee.harness.catalog:claude_bin")
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
local function start_endpoint(record: string, text: string?): string
    local executor = assert(exec.get("bee.placement.native:executor"))
    local environment: {[string]: string}? = nil
    if text then environment = {PATH = "/usr/bin:/bin", BEE_ENDPOINT_TEXT = text} end
    local proc, err = executor:exec(fixture_bin() .. "/gateway-client endpoint " .. record, {env = environment})
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
local function measured(): (string, string, string)
    local snapshot = assert(catalog.snapshot())
    local usable = assert(catalog.usable(snapshot))
    for _, candidate in ipairs(usable) do
        if candidate.binding_id == BINDING then
            local pinned, policy_error = policy.load(POLICY)
            if not pinned then error(tostring(policy_error)) end
            local binding_digest: string = tostring(candidate.binding_digest.entry)
            local profile_digest: string = tostring(candidate.profile_digest.entry)
            local policy_digest: string = tostring(pinned.digest)
            return binding_digest, profile_digest, policy_digest
        end
    end
    error("the Claude binding is not usable on this host")
end
-- The host side: bind the executable and select the endpoint through the
-- policy environment, admit the root and the sentinel source. Nothing here
-- is chosen by the launch request.
local function prepare_host(port: string, claude: string)
    local entry = registry.get(POLICY)
    if not entry then error(POLICY) end
    local data = entry.data :: Object
    data.executables = {claude = claude}
    data.environment = {ANTHROPIC_BASE_URL = "http://127.0.0.1:" .. port}
    apply(entry)
    admit("bee.placement.native:admitted_roots", "roots", {root_ref = ROOT, access = "write"}, function(item: Object): boolean return item.root_ref == ROOT end)
    admit("bee:credential_sources", "sources", {ref = SOURCE, workspace_id = "*", audience = ACTOR, provider = "claude", projection_kinds = {"environment"}}, function(item: Object): boolean return item.ref == SOURCE end)
end
local function thread(): string
    local created = call("bee.threads.service:create", {thread_id = fresh("thread"), idempotency_key = fresh("key"), title = "Claude path"})
    return created.thread_id :: string
end
local function projection_for(workspace: string, attempt_id: string): string
    call("bee.credentials.binding:define", {workspace_id = workspace, name = "anthropic", provider = "claude", source = {kind = "env_variable", ref = SOURCE}})
    local binding_digest, profile_digest, policy_digest = measured()
    local issued = call("bee.credentials.binding:issue_projection", {workspace_id = workspace, name = "anthropic", audience = ACTOR, attempt_id = attempt_id, profile_id = "batch",
        profile_digest = profile_digest, binding_digest = binding_digest, launch_policy_digest = policy_digest, idempotency_key = fresh("key")})
    return issued.projection_id :: string
end
local function request(thread_id: string, attempt_id: string, projections: {string}): Object
    local placement = placement_fixture.resolve()
    return {thread_id = thread_id, action_id = "action-" .. attempt_id, attempt_id = attempt_id, owner_id = ACTOR, owner_incarnation = 1, binding_ref = BINDING,
        profile_id = "batch", brief = "say hi", policy_ref = POLICY, resources = {{name = "project", grant_ref = "host", root_ref = ROOT, subpath = "", access = "write", purpose = "project"}},
        environment = {PATH = "/usr/bin:/bin"}, working_directory = "project", projections = projections, placement_binding_ref = placement.binding_id,
        placement_binding_digest = placement.binding_digest}
end
local function spawn_carrier(request_value: Object): string
    local spawner = process.with_context({}):with_actor(actor):with_scope(scope())
    local pid, err = spawner:spawn_monitored("bee.harness.carrier:process", "bee:workers", request_value, "open", process.pid())
    if not pid then error("spawn carrier: " .. tostring(err)) end
    return tostring(pid)
end
local function await_carrier(pid: string, label: string): Outcome
    local events = assert(process.events())
    local deadline = time.after("120s")
    local outcome: Outcome? = nil
    while not outcome do
        local selected = channel.select({events:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then error(label .. " did not finish") end
        local event = selected.value
        if event.kind == process.event.EXIT and tostring(event.from) == pid then
            local result = event.result or {}
            local value: Object? = nil
            if type(result.value) == "table" then value = result.value :: Object end
            outcome = {value = value, error = result.error and tostring(result.error) or nil}
        end
    end
    return outcome :: Outcome
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
local function define_tests()
    test.describe("Claude authentication path through placement", function()
        test.it("resumes the real Claude session across two native attempts in one thread, or reports the gate open", function()
            local claude = claude_bin()
            if not claude then test.eq(launch.CLAUDE_AUTHENTICATION, "unproven"); return end
            local root = ".wippy/claude-resume-" .. fresh("run")
            shell("mkdir -p " .. root)
            local ok, err = pcall(function()
                local record = root .. "/endpoint.jsonl"
                local port = start_endpoint(record, "bee native answer")
                prepare_host(port, claude)
                local workspace, thread_id = fresh("ws"), thread()
                local first_id, second_id, session_ref = fresh("attempt"), fresh("attempt"), fresh("session")
                local first = request(thread_id, first_id, {projection_for(workspace, first_id)})
                first.session_ref = session_ref
                first.brief = "--version"
                local resources = first.resources :: {Object}
                resources[#resources + 1] = {name = "session", grant_ref = "host-session", root_ref = ROOT, subpath = "", access = "write", purpose = "session"}
                local first_result = await_carrier(spawn_carrier(first), "first native turn")
                if not first_result.value then error("first native turn: " .. tostring(first_result.error)) end
                local first_settlement = first_result.value.settlement :: Object
                test.eq(first_settlement.outcome, "succeeded")
                test.not_nil(first_settlement.resume_ref)
                local before, initial_messages = 0, 0
                for line in shell("cat " .. record):gmatch("[^\n]+") do
                    local item = json.decode(line) :: Object
                    before = before + 1
                    initial_messages = math.max(initial_messages, tonumber(item.messages) or 0)
                end
                local second = request(thread_id, second_id, {projection_for(workspace, second_id)})
                second.action_id, second.session_ref = first.action_id, session_ref
                second.previous_attempt_id = first_id
                second.resources = resources
                second.brief = "Second native prompt"
                local second_result = await_carrier(spawn_carrier(second), "second native turn")
                if not second_result.value then error("second native turn: " .. tostring(second_result.error)) end
                local second_settlement = second_result.value.settlement :: Object
                test.eq(second_settlement.outcome, "succeeded")
                test.eq(second_settlement.resume_ref, first_settlement.resume_ref)
                local seen, resumed_messages = 0, 0
                for line in shell("cat " .. record):gmatch("[^\n]+") do
                    local item = json.decode(line) :: Object
                    seen = seen + 1
                    if seen > before then resumed_messages = math.max(resumed_messages, tonumber(item.messages) or 0) end
                end
                test.is_true(resumed_messages > initial_messages, "native harness did not retain the first turn")
                local actions, turns, receipts = 0, 0, 0
                for _, item in ipairs(records_of(thread_id)) do
                    if item.kind == "action.admitted" then actions = actions + 1 end
                    if item.kind == "turn.request" then
                        turns = turns + 1
                        if item.attempt_id == second_id then test.eq((item.body :: Object).resume_ref, first_settlement.resume_ref) end
                    end
                    if item.kind == "receipt" then receipts = receipts + 1 end
                end
                test.eq(actions, 1); test.eq(turns, 2); test.eq(receipts, 2)
            end)
            stop_endpoint()
            shell("rm -rf " .. root)
            if not ok then error(tostring(err)) end
        end)
        test.it("selects the API-key path with the environment projection and the host-selected endpoint, or reports the gate open", function()
            local claude = claude_bin()
            if not claude then
                test.eq(launch.CLAUDE_AUTHENTICATION, "unproven")
                return
            end
            local version = shell(claude .. " --version")
            if not version:find("Claude Code", 1, true) then error("not the Claude executable: " .. version) end
            local root = ".wippy/claude-runner-" .. fresh("run")
            shell("mkdir -p " .. root)
            local record = root .. "/endpoint.jsonl"
            local port = start_endpoint(record)
            prepare_host(port, claude)
            local workspace = fresh("ws")
            local thread_id, attempt_id = thread(), fresh("attempt")
            local projection_id = projection_for(workspace, attempt_id)
            local outcome = await_carrier(spawn_carrier(request(thread_id, attempt_id, {projection_id})), "claude run")
            if not outcome.value then error("claude run failed: " .. tostring(outcome.error)) end
            local settlement = outcome.value.settlement :: Object
            test.neq(settlement.outcome, "succeeded")
            local recorded = shell("cat " .. record)
            local evidence = evidence_of(attempt_id)
            local kinds: {string} = {}
            for _, item in ipairs(evidence) do kinds[#kinds + 1] = tostring(item.kind) end
            if not recorded:find('"path": "/v1/messages', 1, true) or not recorded:find('"x_api_key": "' .. SENTINEL .. '"', 1, true) then
                error("endpoint saw no api key: [" .. recorded:sub(1, 300):gsub(SENTINEL, "<sentinel>") .. "]; settlement " .. tostring(settlement.outcome) .. " " .. tostring(settlement.reason) .. "; evidence " .. table.concat(kinds, ","))
            end
            local materialized = false
            for _, item in ipairs(evidence) do
                if item.kind == "credential.materialized" then materialized = true end
                test.is_nil(json.encode(item):find(SENTINEL, 1, true))
            end
            test.is_true(materialized)
            for _, item in ipairs(records_of(thread_id)) do
                test.is_nil(json.encode(item):find(SENTINEL, 1, true))
            end
            test.is_nil(json.encode(outcome.value):find(SENTINEL, 1, true))
            stop_endpoint()
            shell("rm -rf " .. root)
            test.eq(launch.CLAUDE_AUTHENTICATION, "unproven")
        end)
    end)
end
return test.run_cases(define_tests)
