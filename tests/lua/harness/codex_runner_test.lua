-- MIT. API-key authentication-path selection for Codex through the real
-- placement runner: the driver-prepared launch, the generated provider
-- configuration written into the private home, the broker-projected
-- sentinel key, the pinned executable and a controlled local endpoint.
-- The endpoint answers 401, so a passing run proves path selection only,
-- never provider acceptance or a completed turn. Without the executable
-- the gate is reported open; without stdin closure placement refuses.
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
local placement = require("placement")
local ACTOR = "bee.test.codex_carrier"
local POLICY = "bee.harness.catalog:codex_fixture_policy"
local BARE_POLICY = "bee.harness.catalog:codex_fixture_policy_bare"
local PROVIDER = "bee.harness.catalog:codex_fixture_provider"
local SOURCE = "bee.harness.catalog:codex_sentinel_key"
local ROOT = "bee.harness.catalog:project_fixture"
local BINDING = "bee.driver.codex:binding"
local SENTINEL = "sk-sentinel-bee-000"
type Object = {[string]: unknown}
type Outcome = {value: Object?, error: string?}
local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end
local scope_names = {"bee.harness.catalog:carrier_client_policy", "bee:thread_create_policy", "bee:thread_observe_policy", "bee:thread_lifecycle_policy",
    "bee:thread_carrier_policy", "bee:carrier_policy", "bee.harness.catalog:carrier_spawn_policy", "bee.harness.catalog:codex_credential_client_policy", "bee:credential_manage_policy", "bee:credential_issue_policy"}
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
local function codex_bin(): string?
    local bin, err = env.get("bee.harness.catalog:codex_bin")
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
-- The endpoint holds each answer for the given seconds after recording
-- the request, so the suite can act while the child is provably waiting.
local function start_endpoint(record: string, hold_seconds: integer, text: string?): string
    local executor = assert(exec.get("bee.placement.native:executor"))
    local environment: {[string]: string}? = nil
    if text then environment = {PATH = "/usr/bin:/bin", BEE_ENDPOINT_TEXT = text} end
    local proc, err = executor:exec(fixture_bin() .. "/endpoint " .. record .. " " .. tostring(hold_seconds), {env = environment})
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
    error("the Codex binding is not usable on this host")
end
local function prepare_host(port: string, codex: string)
    local provider = registry.get(PROVIDER)
    if not provider then error("provider entry") end
    local provider_data = provider.data :: Object
    provider_data.base_url = "http://127.0.0.1:" .. port .. "/v1"
    apply(provider)
    for _, policy_id in ipairs({POLICY, BARE_POLICY}) do
        local entry = registry.get(policy_id)
        if not entry then error(policy_id) end
        local policy_data = entry.data :: Object
        policy_data.executables = {codex = codex}
        apply(entry)
    end
    admit("bee.placement.native:admitted_roots", "roots", {root_ref = ROOT, access = "write"}, function(item: Object): boolean return item.root_ref == ROOT end)
    admit("bee:credential_sources", "sources", {ref = SOURCE, workspace_id = "*", audience = ACTOR, provider = "codex", projection_kinds = {"environment"}}, function(item: Object): boolean return item.ref == SOURCE end)
end
local function thread(): string
    local created = call("bee.threads.service:create", {thread_id = fresh("thread"), idempotency_key = fresh("key"), title = "Codex path"})
    return created.thread_id :: string
end
local function projection_for(workspace: string, attempt_id: string): string
    call("bee.credentials:define", {workspace_id = workspace, name = "openai", provider = "codex", source = {kind = "env_variable", ref = SOURCE}})
    local binding_digest, profile_digest, policy_digest = measured()
    local issued = call("bee.credentials:issue_projection", {workspace_id = workspace, name = "openai", audience = ACTOR, attempt_id = attempt_id, profile_id = "batch",
        profile_digest = profile_digest, binding_digest = binding_digest, launch_policy_digest = policy_digest, idempotency_key = fresh("key")})
    return issued.projection_id :: string
end
local function request(thread_id: string, attempt_id: string, policy_ref: string, projections: {string}): Object
    return {thread_id = thread_id, action_id = "action-" .. attempt_id, attempt_id = attempt_id, owner_id = ACTOR, owner_incarnation = 1, binding_ref = BINDING,
        profile_id = "batch", brief = "say hi", policy_ref = policy_ref, resources = {{name = "project", grant_ref = "host", root_ref = ROOT, subpath = "", access = "write", purpose = "project"}},
        environment = {PATH = "/usr/bin:/bin"}, working_directory = "project", projections = projections}
end
local function spawn_carrier(entry: string, request_value: Object, mode: string, crash_after: string?): string
    local spawner = process.with_context({}):with_actor(actor):with_scope(scope())
    local pid, err = spawner:spawn_monitored(entry, "bee:workers", request_value, mode, process.pid(), crash_after)
    if not pid then error("spawn carrier: " .. tostring(err)) end
    return tostring(pid)
end
local exited: {[string]: Outcome} = {}
local function await_carrier(pid: string, label: string): Outcome
    local events = assert(process.events())
    local deadline = time.after("120s")
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
local function evidence_kinds(attempt_id: string): {string}
    local page = call("bee.placement.native:evidence", {attempt_id = attempt_id, limit = 64})
    local list: {string} = {}
    for _, item in ipairs(page.evidence :: {Object}) do list[#list + 1] = tostring(item.kind) end
    return list
end
local function has(list: {string}, wanted: string): boolean
    for _, item in ipairs(list) do
        if item == wanted then return true end
    end
    return false
end
local function write_phases(records: {Object}): {string}
    local phases: {string} = {}
    for _, item in ipairs(records) do
        local body = item.body :: Object
        if body.type == "extension" then
            local data = body.data :: Object
            if data.event_name == "bee.carrier.write" then
                local payload = json.decode(tostring(data.payload_json)) :: Object
                phases[#phases + 1] = tostring(payload.phase)
            end
        end
    end
    return phases
end
function bounds_content(value: unknown): string
    if type(value) ~= "table" then return "" end
    return tostring((value :: Object).text or "")
end
local function define_tests()
    test.describe("Codex authentication path through placement", function()
        test.it("resumes the real Codex session across two native attempts in one thread, or reports the gate open", function()
            local codex = codex_bin()
            if not codex then test.eq(launch.CODEX_AUTHENTICATION, "unproven"); return end
            local root = ".wippy/codex-resume-" .. fresh("run")
            shell("mkdir -p " .. root)
            local ok, err = pcall(function()
                local record = root .. "/endpoint.jsonl"
                local port = start_endpoint(record, 0, "bee native answer")
                prepare_host(port, codex)
                local workspace, thread_id = fresh("ws"), thread()
                local first_id, second_id, session_ref = fresh("attempt"), fresh("attempt"), fresh("session")
                local first = request(thread_id, first_id, POLICY, {projection_for(workspace, first_id)})
                first.session_ref = session_ref
                first.brief = "First native prompt"
                local resources = first.resources :: {Object}
                resources[#resources + 1] = {name = "session", grant_ref = "host-session", root_ref = ROOT, subpath = "", access = "write", purpose = "session"}
                local first_result = await_carrier(spawn_carrier("bee.harness.carrier:process", first, "open", nil), "first native turn")
                if not first_result.value then error("first native turn: " .. tostring(first_result.error)) end
                local first_settlement = first_result.value.settlement :: Object
                test.eq(first_settlement.outcome, "succeeded")
                test.not_nil(first_settlement.resume_ref)
                local before, initial_messages = 0, 0
                for line in shell("cat " .. record):gmatch("[^\n]+") do
                    local item = json.decode(line) :: Object
                    before = before + 1
                    initial_messages = math.max(initial_messages, tonumber(item.input_items) or 0)
                end
                local second = request(thread_id, second_id, POLICY, {projection_for(workspace, second_id)})
                second.action_id, second.session_ref = first.action_id, session_ref
                second.previous_attempt_id = first_id
                second.resources = resources
                second.brief = "Second native prompt"
                local second_result = await_carrier(spawn_carrier("bee.harness.carrier:process", second, "open", nil), "second native turn")
                if not second_result.value then error("second native turn: " .. tostring(second_result.error)) end
                local second_settlement = second_result.value.settlement :: Object
                test.eq(second_settlement.outcome, "succeeded")
                test.eq(second_settlement.resume_ref, first_settlement.resume_ref)
                local seen, resumed_messages = 0, 0
                for line in shell("cat " .. record):gmatch("[^\n]+") do
                    local item = json.decode(line) :: Object
                    seen = seen + 1
                    if seen > before then resumed_messages = math.max(resumed_messages, tonumber(item.input_items) or 0) end
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
        test.it("selects the API-key path through the runner with a generated configuration and a projected sentinel, or reports why not", function()
            local codex = codex_bin()
            if not codex then
                test.eq(launch.CODEX_AUTHENTICATION, "unproven")
                return
            end
            local capabilities_reply = placement.capabilities()
            if not capabilities_reply.ok then error("placement capabilities: " .. tostring(capabilities_reply.error and capabilities_reply.error.message)) end
            local capabilities = capabilities_reply.value :: Object
            local root = ".wippy/codex-runner-" .. fresh("run")
            shell("mkdir -p " .. root)
            local record = root .. "/endpoint.jsonl"
            local port = start_endpoint(record, 5)
            prepare_host(port, codex)
            local workspace = fresh("ws")
            local thread_id, attempt_id = thread(), fresh("attempt")
            local projection_id = projection_for(workspace, attempt_id)
            local launch_request = request(thread_id, attempt_id, POLICY, {projection_id})
            if capabilities.stdin_close ~= true then
                local refused = await_carrier(spawn_carrier("bee.harness.carrier:process", launch_request, "open", nil), "unsupported stdin closure")
                test.is_nil(refused.value)
                test.is_true(tostring(refused.error):find("cannot close a child's stdin", 1, true) ~= nil)
                stop_endpoint()
                test.eq(launch.CODEX_AUTHENTICATION, "unproven")
                return
            end
            local pid = spawn_carrier("bee.harness.carrier:process", launch_request, "open", nil)
            -- The late write goes in once the endpoint has recorded the
            -- request, while the child waits on the held answer.
            local requested = false
            for _ = 1, 400 do
                if shell("cat " .. record .. " 2>/dev/null"):find("/v1/responses", 1, true) then requested = true break end
                time.sleep("50ms")
            end
            if not requested then error("codex never reached the endpoint") end
            process.send(pid, "bee.carrier.input", {write_id = "late", data = "more\\n"})
            local outcome = await_carrier(pid, "codex run")
            if not outcome.value then error("codex run failed: " .. tostring(outcome.error)) end
            local settlement = outcome.value.settlement :: Object
            test.neq(settlement.outcome, "succeeded")
            local recorded = shell("cat " .. record)
            local kinds = evidence_kinds(attempt_id)
            if not recorded:find('"path": "/v1/responses"', 1, true) or not recorded:find('"authorization": "Bearer ' .. SENTINEL .. '"', 1, true) then
                local notices: {string} = {}
                for _, item in ipairs(records_of(thread_id)) do
                    local body = item.body :: Object
                    if body.type == "notice" or body.type == "turn.signal" or body.type == "extension" then
                        local data = body.data :: Object
                        local text = tostring((bounds_content(data.content)):sub(1, 200))
                        notices[#notices + 1] = tostring(data.code or data.event_name or data.phase) .. ":" .. text .. tostring(data.payload_json or ""):sub(1, 160)
                    end
                end
                local details: {string} = {}
                local page = call("bee.placement.native:evidence", {attempt_id = attempt_id, limit = 64})
                for _, item in ipairs(page.evidence :: {Object}) do
                    if item.kind == "configuration.materialized" then
                        details[#details + 1] = tostring(item.detail)
                        local at = tostring(item.detail):match(" at (.+)$")
                        if at then details[#details + 1] = "file: " .. shell("cat " .. at .. " 2>&1 | head -c 400; ls -la " .. at .. " 2>&1") end
                    end
                end
                error("endpoint saw no bearer: [" .. recorded:sub(1, 300):gsub(SENTINEL, "<sentinel>") .. "]; settlement " .. tostring(settlement.outcome) .. " " .. tostring(settlement.reason) .. "; evidence " .. table.concat(kinds, ",") .. "; configuration " .. table.concat(details, " ; ") .. "; stream " .. table.concat(notices, " | "):gsub(SENTINEL, "<sentinel>"))
            end
            for _, wanted in ipairs({"configuration.materialized", "credential.materialized", "stdin.accepted", "stdin.closed"}) do
                if not has(kinds, wanted) then error("evidence lacks " .. wanted .. ": " .. table.concat(kinds, ",")) end
            end
            local records = records_of(thread_id)
            for _, item in ipairs(records) do
                test.is_nil(json.encode(item):find(SENTINEL, 1, true))
            end
            if not has(write_phases(records), "refused") then error("no refused write recorded; writes " .. table.concat(write_phases(records), ",")) end
            -- Changed configuration: a plan pinned before placement start no
            -- longer digests once the provider changes, so a resume refuses.
            local changed_thread, changed_attempt = thread(), fresh("attempt")
            local changed_request = request(changed_thread, changed_attempt, POLICY, {projection_for(workspace, changed_attempt)})
            local crashed = await_carrier(spawn_carrier("bee.harness.catalog:carrier_faulted", changed_request, "open", "attached"), "attach crash")

            local provider = registry.get(PROVIDER)
            if not provider then error("provider entry") end
            local provider_data = provider.data :: Object
            local previous_model = provider_data.model
            provider_data.model = "gpt-5-codex"
            apply(provider)
            local resumed = await_carrier(spawn_carrier("bee.harness.catalog:carrier_faulted", changed_request, "resume", nil), "changed provider")
            test.is_nil(resumed.value)
            if not tostring(resumed.error):find("no longer digests as recorded", 1, true) then
                local stored = call("bee.threads.carrier:checkpoint", {thread_id = changed_thread, attempt_id = changed_attempt})
                error("resume did not refuse the changed provider: " .. tostring(resumed.error) .. "; crash " .. tostring(crashed.error) .. "; stored " .. json.encode(stored):sub(1, 600))
            end
            provider_data.model = previous_model
            apply(provider)
            -- Missing configuration: a policy without a provider refuses the plan.
            local bare = await_carrier(spawn_carrier("bee.harness.carrier:process", request(thread(), fresh("attempt"), BARE_POLICY, {}), "open", nil), "bare policy")
            test.is_nil(bare.value)
            if not tostring(bare.error):find("provider_ref", 1, true) then error("bare policy did not refuse: " .. tostring(bare.error)) end
            stop_endpoint()
            shell("rm -rf " .. root)
            test.eq(launch.CODEX_AUTHENTICATION, "unproven")
        end)
    end)
end
return test.run_cases(define_tests)
