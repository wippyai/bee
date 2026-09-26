-- MIT. The acceptance for the managed-run tools through the real MCP surface.
-- A scripted orchestrator agent runs under its own launch policy, which admits
-- thread_launch, launch_definitions, capabilities and the managed-run tools and
-- allow-lists exactly one Codex worker definition. It launches a Codex batch
-- worker on a NEW thread, is told by thread_notify and wakes on thread_wait when
-- the child ends, reads the child's own thread by naming it member_thread,
-- queries the run with run_status, steers the child once, then launches a second
-- worker on a new thread and cancels it with run_cancel. The child's gateway
-- tools are its own launch policy's, and a run identity the orchestrator never
-- launched is refused.
local test = require("test")
local principals = require("principals")
local funcs = require("funcs")
local security = require("security")
local process = require("process")
local registry = require("registry")
local env = require("env")
local time = require("time")
local channel = require("channel")
local json = require("json")
local placement_fixture = require("placement_fixture")
local ACTOR = "bee.test.agent_run_acceptance"
local ORCHESTRATOR_POLICY = "bee.harness.catalog:agent_run_orchestrator_policy"
local WORKER_POLICY = "bee.harness.catalog:agent_run_worker_policy"
local WORKER_DEFINITION = "bee.harness.catalog:agent_run_codex_worker"
local PROVIDER = "bee.harness.catalog:codex_fixture_provider"
local SOURCE = "bee.harness.catalog:codex_sentinel_key"
local ROOT = "bee.harness.catalog:project_fixture"
local ORCHESTRATOR_BINDING = "bee.driver.claude:binding"
local WORKER_BINDING = "bee.driver.codex:binding"
local CARRIER = "bee.harness.catalog:carrier_faulted"
local MARKER = "agent-run-worker-answer"
type Object = {[string]: unknown}
local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end
local scope_names = {"bee.harness.catalog:carrier_client_policy", "bee.harness.catalog:gateway_client_policy", "bee.security.threads:thread_create_policy", "bee.security.threads:thread_observe_policy",
    "bee.security.threads:thread_lifecycle_policy", "bee.security.threads:thread_carrier_policy", "bee.security.harness:carrier_policy", "bee.harness.catalog:carrier_spawn_policy", "bee.security.gateway:gateway_manage_policy", "bee.security.gateway:gateway_admit_policy",
    "bee.security.resources:resource_manage_policy", "bee.security.credentials:credential_manage_policy", "bee.harness.catalog:codex_credential_client_policy", "bee.security.credentials:credential_issue_policy"}
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
local function setting(id: string, what: string): string
    local value, err = env.get(id)
    if err or type(value) ~= "string" or value == "" then error(what .. " is not set for the test runtime") end
    return value
end
local function fixture_bin(): string
    return setting("bee.harness.catalog:fixture_bin", "BEE_FIXTURE_BIN")
end
local function stream(name: string): string
    return setting("bee.harness.catalog:fixture_streams", "BEE_FIXTURE_STREAMS") .. "/" .. name
end
-- The host entries this acceptance temporarily widens, copied by value so a
-- mutation made in place is really undone for every later suite.
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
    for _, ref in ipairs({"bee:resource_roots", "bee:placement_resource_mode", "bee:placement_admitted_roots", "bee:harness_setup", "bee:credential_sources"}) do
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
    setup_data.credentials = {codex_login = {provider = "codex", source = {kind = "env_variable", ref = SOURCE}, optional = true}}
    apply(setup)
    local sources = assert(registry.get("bee:credential_sources"))
    local sources_data = sources.data :: Object
    local list = sources_data.sources :: {Object}
    list[#list + 1] = {ref = SOURCE, workspace_id = "*", audience = ACTOR, provider = "codex", projection_kinds = {"environment"}}
    apply(sources)
end
-- The orchestrator runs the Claude fixture with the launch instruction in its
-- environment; the worker policy carries the Codex fixture and the worker
-- stream, so the children the real launch pipeline starts are the scripted
-- Codex workers. A linger keeps each worker alive long enough to cancel the
-- second one deterministically.
local function bind_policies()
    local bin = fixture_bin()
    local harness_dir = bin:match("^(.*)/bin/?$")
    if not harness_dir then error("BEE_FIXTURE_BIN does not end in bin: " .. bin) end
    local orchestrator = assert(registry.get(ORCHESTRATOR_POLICY))
    local orchestrator_data = orchestrator.data :: Object
    orchestrator_data.executables = {claude = bin .. "/claude"}
    orchestrator_data.environment = {}
    apply(orchestrator)
    local worker = assert(registry.get(WORKER_POLICY))
    local worker_data = worker.data :: Object
    worker_data.executables = {codex = harness_dir .. "/codex/codex"}
    worker_data.environment = {BEE_FIXTURE_GATEWAY = "1", BEE_FIXTURE_GATEWAY_WORKER = MARKER, BEE_FIXTURE_WORKER_MARKER = MARKER,
        BEE_FIXTURE_STREAM = stream("codex/exec-json-1/plain.jsonl"), BEE_FIXTURE_LINGER = "8"}
    apply(worker)
    local provider = assert(registry.get(PROVIDER))
    local provider_data = provider.data :: Object
    provider_data.base_url = "http://127.0.0.1:1/v1"
    apply(provider)
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
-- Both scripted roles commit stderr notices asynchronously. Watch the thread
-- until the requested role's notice is durable, even after its carrier exits.
local function report_with(thread_id: string, field: string): Object
    local guard_ms = math.floor(time.now():unix_nano() / 1000000) + 180000
    local cursor = 0
    while true do
        local page = call("bee.threads.service:read_after", {thread_id = thread_id, cursor = cursor, limit = 64})
        for _, item in ipairs(page.records :: {Object}) do
            if item.kind == "observation" and item.source == "stream" then
                local data = (item.body :: Object).data :: Object
                if data.type == "notice" and (data.code == "stderr" or data.code == "informational") then
                    local text = tostring((data.content :: Object).text)
                    local envelope = json.decode(text)
                    if type(envelope) == "table" and type((envelope :: Object).content) == "string" then
                        text = (envelope :: Object).content :: string
                    end
                    local start = text:find("gateway:", 1, true)
                    if start then
                        local decoded, err = json.decode(text:sub(start + 8))
                        if err or type(decoded) ~= "table" then error("gateway report unreadable: " .. text) end
                        local report = decoded :: Object
                        if report[field] ~= nil then return report end
                    end
                end
            end
        end
        cursor = math.floor(tonumber(page.scanned_through) or cursor)
        if page.has_more ~= true then
            local remaining = guard_ms - math.floor(time.now():unix_nano() / 1000000)
            if remaining <= 0 then break end
            call("bee.threads.delivery:watch", {thread_id = thread_id, after_sequence = cursor, wait_ms = remaining})
        end
    end
    error("no gateway report with " .. field .. " on thread " .. thread_id)
end
local function open_gateway()
    local entry = registry.get("bee:gateway_endpoint")
    if not entry then error("gateway endpoint entry") end
    call("bee.gateway.binding:open", {address = tostring((entry.data :: Object).address)})
end
local function admission(policy_ref: string, thread_id: string, attempt_id: string, workspace_id: string): Object
    local placement = placement_fixture.resolve()
    return {thread_id = thread_id, action_id = "action-" .. attempt_id, attempt_id = attempt_id, owner_id = ACTOR, owner_incarnation = 1, binding_ref = ORCHESTRATOR_BINDING,
        profile_id = "batch", brief = "orchestrate a run", policy_ref = policy_ref, workspace_id = workspace_id,
        resources = {{name = "project", grant_ref = "host", root_ref = ROOT, subpath = "", access = "write", purpose = "project"}},
        environment = {}, working_directory = "project", placement_binding_ref = placement.binding_id, placement_binding_digest = placement.binding_digest}
end
local function spawn_carrier(request_value: Object): string
    local pid, err = process.with_context({}):with_actor(principals.actor(ACTOR, request_value.workspace_id)):with_scope(scope()):spawn_monitored(CARRIER, "bee:workers", request_value, "open", process.pid())
    if not pid then error("spawn carrier: " .. tostring(err)) end
    return tostring(pid)
end
local function await_carrier(pid: string, label: string): Object
    local events, events_error = process.events()
    if not events then error(label .. ": events: " .. tostring(events_error)) end
    local deadline = time.after("180s")
    while true do
        local selected = channel.select({events:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then error(label .. " did not finish") end
        local event = selected.value
        if event.kind == process.event.EXIT and tostring(event.from) == pid then
            local result = event.result or {}
            if result.error then error(label .. " failed: " .. tostring(result.error)) end
            return (result.value or {}) :: Object
        end
    end
    return {}
end
local function define_tests()
    test.describe("Managed run acceptance", function()
        local workspace = fresh("agent-run-ws")
        local thread_id = fresh("agent-run-thread")
        test.it("launches a Codex worker on a new thread, follows its run by notify and wait, steers it, and cancels a second worker", function()
            prepare_host()
            open_gateway()
            bind_policies()
            call("bee.threads.service:create", {thread_id = thread_id, idempotency_key = thread_id .. "-create", title = "Orchestrator run"})
            call("bee.resources.binding:associate", {workspace_id = workspace, name = "project", root_ref = ROOT, subpath = "", allowed_access = "write"})
            call("bee.resources.binding:associate", {workspace_id = workspace, name = "session", root_ref = ROOT, subpath = "", allowed_access = "write"})
            local ok, failure = pcall(function()
            local orchestrator = admission(ORCHESTRATOR_POLICY, thread_id, fresh("orchestrator-attempt"), workspace)
            local first_title = fresh("child-thread")
            local second_title = fresh("cancel-thread")
            orchestrator.environment = {BEE_FIXTURE_GATEWAY = "1", BEE_FIXTURE_REPORT_STREAM = "1", BEE_FIXTURE_GATEWAY_ORCHESTRATOR_RUN = WORKER_DEFINITION,
                BEE_FIXTURE_GATEWAY_RUN_BRIEF = "answer the orchestrator", BEE_FIXTURE_WORKER_MARKER = MARKER,
                BEE_FIXTURE_ORCHESTRATOR_THREAD_TITLE = first_title, BEE_FIXTURE_ORCHESTRATOR_CANCEL_TITLE = second_title,
                BEE_FIXTURE_STREAM = stream("claude/stream-json-2/plain.jsonl")}
            local outcome = await_carrier(spawn_carrier(orchestrator), "orchestrator carrier")
            test.eq((outcome.settlement :: Object).outcome, "succeeded")
            local seen = report_with(thread_id, "first_launch_ok")
            if seen.first_launch_ok ~= true then error("the orchestrator did not launch the first worker: " .. tostring(json.encode(seen))) end
            -- The shipped managed-run tools are actually offered to the agent.
            local tools = seen.orchestrator_tools :: {string}
            local offered: {[string]: boolean} = {}
            for _, name in ipairs(tools) do offered[name] = true end
            for _, name in ipairs({"thread_launch", "launch_definitions", "capabilities", "run_status", "run_wait", "run_cancel"}) do
                test.is_true(offered[name] == true, "the orchestrator was not offered " .. name)
            end
            -- The capabilities report admits launch_definitions whenever the
            -- launch tool is offered; discovery must be admitted by the same
            -- host-selected launch policy, not advertised and then refused.
            test.eq(seen.definitions_call_ok, true, "launch_definitions was offered but refused")
            test.eq(seen.definitions_count, 1, "launch_definitions did not report the allow-listed definition")
            -- The child ran on a thread of its own, was reached by member_thread,
            -- answered, settled, and was notified and waited on.
            test.not_nil(seen.first_thread)
            test.is_true(tostring(seen.first_thread) ~= thread_id, "the child ran on the caller's own thread, not a new one")
            test.eq(seen.first_answered, true, "the child did not answer on its thread")
            test.eq(seen.first_settled, true, "the child did not settle a terminal receipt")
            test.eq(seen.notify_fired, true, "the notice did not land on the orchestrator thread: " .. tostring(json.encode({first_notify_ok = seen.first_notify_ok,
                first_notify_status = seen.first_notify_status, first_answered = seen.first_answered, first_settled = seen.first_settled})))
            test.eq(seen.run_status_ok, true, "run_status refused the caller's own run")
            test.eq(seen.run_state, "ended", "run_status did not read the settled state")
            test.eq(seen.run_outcome, "succeeded", "run_status did not read the settled outcome")
            -- The steer landed on the child's own thread.
            test.eq(seen.steer_ok, true, "the steer was refused")
            test.eq(seen.steer_seen, true, "the steer is not durable on the child thread")
            -- A run the orchestrator never launched is refused.
            test.eq(seen.foreign_refused, true, "an unlaunched run was readable")
            -- The second worker was launched on a new thread and cancelled.
            test.eq(seen.second_launch_ok, true, "the second worker did not launch")
            test.eq(seen.cancel_ok, true, "run_cancel refused the second worker")
            test.eq(seen.cancel_replay_ok, true, "the cancel replay did not return")
            test.eq(seen.second_status_ok, true, "run_status refused the second worker")
            test.eq(seen.second_final_state, "ended", "the cancelled run did not end")
            test.eq(seen.second_final_outcome, "cancelled", "the cancelled run did not report cancelled")
            test.not_nil(seen.second_thread)
            end)
            restore_host()
            if not ok then error(tostring(failure)) end
        end)
    end)
end
return test.run_cases(define_tests)
