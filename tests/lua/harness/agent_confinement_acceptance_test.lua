-- MIT. The orchestrator confinement acceptance: a worker launched through
-- the orchestrator's own thread_launch admission runs as a real placement
-- child with a private attempt home, and the probe inside it verifies the
-- confinement vantage the worker policy promises. A literal read failure
-- for a file outside the workdir needs an OS sandbox, which is a separate
-- Wippy runtime feature; this acceptance pins what the cheap step changes:
-- no real HOME, no host file in the attempt home, the granted workdir as
-- the working directory, an exact environment, and the admission refusal
-- for a workdir the host never granted.
local test = require("test")
local principals = require("principals")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local env = require("env")
local time = require("time")
local json = require("json")

local ACTOR = "bee.test.agent_confinement"
local ORCHESTRATOR_POLICY = "bee.harness.catalog:agent_confinement_orchestrator_policy"
local WORKER_POLICY = "bee.harness.catalog:agent_confinement_worker_policy"
local WORKER_DEFINITION = "bee.harness.catalog:agent_confinement_worker"
local ROOT = "bee.harness.catalog:project_fixture"
local BINDING = "bee.driver.claude:binding"
local SOURCE = "bee.harness.catalog:alternate_setup_key"
local CALL = "bee.harness.launch:agent_launch_call"
local FACADE_POLICY = "bee.harness.launch:agent_launch_facade_policy"
local BINDING_KEY = "bee.gateway.binding"
local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000000)) .. "-" .. tostring(counter)
end
type Object = {[string]: unknown}
local scope_names = {FACADE_POLICY, "bee.harness.catalog:carrier_client_policy", "bee.harness.catalog:gateway_client_policy",
    "bee.security.threads:thread_create_policy", "bee.security.threads:thread_observe_policy",
    "bee.security.threads:thread_lifecycle_policy", "bee.security.threads:thread_carrier_policy", "bee.security.harness:carrier_policy",
    "bee.harness.catalog:carrier_spawn_policy", "bee.security.gateway:gateway_manage_policy", "bee.security.gateway:gateway_admit_policy",
    "bee.security.resources:resource_manage_policy", "bee.security.credentials:credential_manage_policy"}
local function scope(): security.Scope
    local policies: {security.Policy} = {}
    for index, name in ipairs(scope_names) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    return security.new_scope(policies)
end
local function call(target: string, request: unknown): Object
    local reply, err = funcs.new():with_actor(principals.actor(ACTOR, principals.workspace(request))):with_scope(scope()):call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    local value = reply :: Object
    if value.ok ~= true then
        local fault = value.error :: Object
        error(target .. ": " .. tostring(fault.code) .. ": " .. tostring(fault.message))
    end
    return value.value :: Object
end
local function apply(entry: {[string]: unknown})
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("apply: " .. tostring(err)) end
end
local function fixture_bin(): string
    local bin, err = env.get("bee.harness.catalog:fixture_bin")
    if err or type(bin) ~= "string" or bin == "" then error("BEE_FIXTURE_BIN is not set for the test runtime") end
    return bin
end
local function stream(name: string): string
    local base, err = env.get("bee.harness.catalog:fixture_streams")
    if err or type(base) ~= "string" or base == "" then error("BEE_FIXTURE_STREAMS is not set for the test runtime") end
    return base .. "/claude/stream-json-2/" .. name
end
local saved: {[string]: unknown} = {}
local function copy_of(value: unknown): unknown
    local encoded, encode_error = json.encode(value)
    if not encoded then error("copy host entry: " .. tostring(encode_error)) end
    local decoded, decode_error = json.decode(encoded)
    if decode_error then error("copy host entry: " .. tostring(decode_error)) end
    return decoded
end
local function remember(ref: string)
    local entry = registry.get(ref)
    if entry then saved[ref] = copy_of(entry.data) end
end
local function restore_host()
    for ref, data in pairs(saved) do
        local entry = registry.get(ref)
        if entry then
            entry.data = copy_of(data)
            apply(entry)
        end
    end
end
local function prepare_host()
    for _, ref in ipairs({"bee:resource_roots", "bee:placement_resource_mode", "bee:placement_admitted_roots", "bee:harness_setup", "bee:credential_sources", WORKER_POLICY}) do
        remember(ref)
    end
    local mode = assert(registry.get("bee:placement_resource_mode"))
    mode.data = {mode = "host_configured"}
    apply(mode)
    local roots = assert(registry.get("bee:resource_roots"))
    local roots_data = roots.data :: Object
    local available = roots_data.roots :: {Object}
    local listed = false
    for _, root in ipairs(available) do if root.root_ref == ROOT then listed = true end end
    if not listed then
        available[#available + 1] = {root_ref = ROOT, access = "write"}
        apply(roots)
    end
    local admitted_roots = assert(registry.get("bee:placement_admitted_roots"))
    local admitted_data = admitted_roots.data :: Object
    local admitted = admitted_data.roots :: {Object}
    local present = false
    for _, root in ipairs(admitted) do if root.root_ref == ROOT then present = true end end
    if not present then
        admitted[#admitted + 1] = {root_ref = ROOT, access = "write"}
        apply(admitted_roots)
    end
    local setup = assert(registry.get("bee:harness_setup"))
    local setup_data = setup.data :: Object
    setup_data.roots = {project = ROOT, session = ROOT}
    setup_data.credentials = {anthropic = {provider = "claude", source = {kind = "env_variable", ref = SOURCE}}}
    apply(setup)
    local sources = assert(registry.get("bee:credential_sources"))
    local sources_data = sources.data :: Object
    local list = sources_data.sources :: {Object}
    list[#list + 1] = {ref = SOURCE, workspace_id = "*", audience = ACTOR, provider = "claude", projection_kinds = {"environment"}}
    apply(sources)
    -- The worker policy carries the probe executable and the canary paths;
    -- the real HOME value is host-selected, so only the test run knows it.
    local home, home_error = env.get("bee.env:machine_home")
    if home_error or type(home) ~= "string" or home == "" then error("machine HOME is not selected for the test runtime") end
    local worker = assert(registry.get(WORKER_POLICY))
    local worker_data = worker.data :: Object
    worker_data.executables = {claude = fixture_bin() .. "/confinement-probe"}
    worker_data.environment = {BEE_FIXTURE_STREAM = stream("plain.jsonl"), BEE_CONFINEMENT_REAL_HOME = home}
    apply(worker)
end
local function open_gateway()
    local entry = registry.get("bee:gateway_endpoint")
    if not entry then error("gateway endpoint entry") end
    call("bee.gateway.binding:open", {address = tostring((entry.data :: Object).address)})
end
local function facade(request: Object, policy_ref: string, thread_id: string, workspace_id: string): Object
    local binding: Object = {binding_id = "binding-confinement", thread_id = thread_id, action_id = fresh("confinement-action"),
        attempt_id = fresh("confinement-attempt"), policy_ref = policy_ref, workspace_id = workspace_id}
    local executor = funcs.new():with_actor(principals.actor(ACTOR, workspace_id)):with_scope(scope())
    local bound = assert(executor:with_context({[BINDING_KEY] = binding}))
    local reply, err = bound:call(CALL, request)
    if err then error("agent launch call: " .. tostring(err)) end
    return reply :: Object
end
local function await_receipt(thread_id: string, attempt_id: string)
    local guard_ms = math.floor(time.now():unix_nano() / 1000000) + 180000
    local cursor = 0
    while true do
        local page = call("bee.threads.service:read_after", {thread_id = thread_id, cursor = cursor, limit = 64, filter = {kinds = {"receipt"}}})
        for _, item in ipairs(page.records :: {Object}) do
            if item.attempt_id == attempt_id then return end
        end
        cursor = math.floor(tonumber(page.scanned_through) or cursor)
        if page.has_more ~= true then
            local remaining = guard_ms - math.floor(time.now():unix_nano() / 1000000)
            if remaining <= 0 then error("confinement worker did not settle; attempt=" .. attempt_id) end
            call("bee.threads.delivery:watch", {thread_id = thread_id, after_sequence = cursor, wait_ms = remaining})
        end
    end
end
local function receipt_outcome(thread_id: string, attempt_id: string): string
    local page = call("bee.threads.service:read_after", {thread_id = thread_id, cursor = 0, limit = 64, filter = {kinds = {"receipt"}}})
    for _, item in ipairs(page.records :: {Object}) do
        if item.attempt_id == attempt_id then return tostring((item.body :: Object).outcome) end
    end
    error("confinement worker has no durable receipt")
end
local function define_tests()
    test.describe("Orchestrator worker confinement", function()
        local workspace = fresh("confinement-workspace")
        local thread_id = fresh("confinement-thread")
        test.it("runs the orchestrator's worker with a private home and the granted workdir, and refuses an ungranted one", function()
            prepare_host()
            open_gateway()
            local ok, failure = pcall(function()
                call("bee.threads.service:create", {thread_id = thread_id, idempotency_key = thread_id .. "-create", title = "Confinement acceptance"})
                call("bee.resources.binding:associate", {workspace_id = workspace, name = "project", root_ref = ROOT, subpath = "", allowed_access = "write"})
                call("bee.resources.binding:associate", {workspace_id = workspace, name = "session", root_ref = ROOT, subpath = "", allowed_access = "write"})
                -- The orchestrator's allow-list admits the worker, so the
                -- facade starts it through the ordinary pipeline; the probe
                -- inside asserts the confinement vantage and replays the
                -- standard stream, and a nonzero probe exit fails the run.
                local launched = facade({definition_ref = WORKER_DEFINITION, brief = "probe the confinement vantage",
                    idempotency_key = fresh("confinement-key"), workdir = {resource = "project"}}, ORCHESTRATOR_POLICY, thread_id, workspace)
                if (launched :: Object).ok ~= true then
                    local fault = (launched :: Object).error :: Object
                    error("orchestrator launch: " .. tostring(fault.code) .. ": " .. tostring(fault.message))
                end
                local admitted = (launched :: Object).value :: Object
                test.eq(admitted.definition_ref, WORKER_DEFINITION)
                test.eq(admitted.thread_id, thread_id)
                local child_attempt = tostring(admitted.attempt_id)
                await_receipt(thread_id, child_attempt)
                test.eq(receipt_outcome(thread_id, child_attempt), "succeeded")
                local status = call("bee.placement.native.binding:status", {attempt_id = child_attempt})
                test.eq((status.attempt :: Object).execution_state, "exited")
                test.eq(((status.attempt :: Object).exit :: Object).code, 0)
                pcall(function() call("bee.placement.native.binding:cleanup", {attempt_id = child_attempt}) end)
                -- A workdir the host never granted never starts: the launch
                -- cannot reach a file outside its admitted workdir.
                local refused = facade({definition_ref = WORKER_DEFINITION, brief = "reach outside",
                    idempotency_key = fresh("confinement-outside-key"), workdir = {resource = "outside-nowhere"}}, ORCHESTRATOR_POLICY, thread_id, workspace)
                test.eq((refused :: Object).ok, false)
            end)
            restore_host()
            if not ok then error(tostring(failure)) end
        end)
    end)
end
return test.run_cases(define_tests)
