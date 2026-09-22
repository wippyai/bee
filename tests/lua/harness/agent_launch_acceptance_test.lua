-- MIT. The acceptance for thread_launch through the real MCP surface. A
-- scripted orchestrator agent runs under its own launch policy, which admits
-- thread_launch and allow-lists exactly one worker definition, and it calls
-- thread_launch over the real gateway. The owner operation starts the
-- worker's own managed carrier through the ordinary launch pipeline, the
-- scripted worker reads its thread, posts its answer and settles, and the
-- orchestrator's thread_wait returns. The worker's gateway tools are its own
-- launch policy's, and lineage records the orchestrator's action as parent.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local process = require("process")
local registry = require("registry")
local env = require("env")
local time = require("time")
local channel = require("channel")
local json = require("json")
local placement_fixture = require("placement_fixture")
local ACTOR = "bee.test.agent_launch_acceptance"
local ORCHESTRATOR_POLICY = "bee.harness.catalog:agent_launch_orchestrator_policy"
local WORKER_POLICY = "bee.harness.catalog:agent_launch_worker_policy"
local WORKER_DEFINITION = "bee.harness.catalog:agent_launch_accepted_worker"
local ROOT = "bee.harness.catalog:project_fixture"
local BINDING = "bee.driver.claude:binding"
local CARRIER = "bee.harness.catalog:carrier_faulted"
local MARKER = "agent-launch-worker-answer"
type Object = {[string]: unknown}
local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end
local scope_names = {"bee.harness.catalog:carrier_client_policy", "bee.harness.catalog:gateway_client_policy", "bee:thread_create_policy", "bee:thread_observe_policy",
    "bee:thread_lifecycle_policy", "bee:thread_carrier_policy", "bee:carrier_policy", "bee.harness.catalog:carrier_spawn_policy", "bee:gateway_manage_policy", "bee:gateway_admit_policy",
    "bee:resource_manage_policy", "bee:credential_manage_policy"}
local function scope(): security.Scope
    local policies: {security.Policy} = {}
    for index, name in ipairs(scope_names) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    return security.new_scope(policies)
end
local actor = security.new_actor(ACTOR)
local function call(target: string, request: unknown): Object
    local reply, err = funcs.new():with_actor(actor):with_scope(scope()):call(target, request)
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
    for _, ref in ipairs({"bee:resource_roots", "bee.placement.native:resource_mode", "bee.placement.native:admitted_roots", "bee:harness_setup", "bee:credential_sources"}) do
        remember(ref)
    end
    local mode = assert(registry.get("bee.placement.native:resource_mode"))
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
    local admitted_roots = assert(registry.get("bee.placement.native:admitted_roots"))
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
    setup_data.credentials = {anthropic = {provider = "claude", source = {kind = "env_variable", ref = "bee.harness.catalog:alternate_setup_key"}}}
    apply(setup)
    local sources = assert(registry.get("bee:credential_sources"))
    local sources_data = sources.data :: Object
    local list = sources_data.sources :: {Object}
    list[#list + 1] = {ref = "bee.harness.catalog:alternate_setup_key", workspace_id = "*", audience = ACTOR, provider = "claude", projection_kinds = {"environment"}}
    apply(sources)
end
-- The orchestrator runs the fixture executable with the launch instruction in
-- its environment; the worker policy carries the worker instruction, so the
-- child that the real launch pipeline starts is the scripted worker.
local function bind_policies()
    local orchestrator = assert(registry.get(ORCHESTRATOR_POLICY))
    local data = orchestrator.data :: Object
    data.executables = {claude = fixture_bin() .. "/claude"}
    data.environment = {}
    data.gateway_tools = {"thread_read", "thread_wait", "thread_launch"}
    data.agent_launch = {WORKER_DEFINITION}
    apply(orchestrator)
    local worker = assert(registry.get(WORKER_POLICY))
    local worker_data = worker.data :: Object
    worker_data.executables = {claude = fixture_bin() .. "/claude"}
    worker_data.environment = {BEE_FIXTURE_GATEWAY = "1", BEE_FIXTURE_GATEWAY_WORKER = MARKER, BEE_FIXTURE_WORKER_MARKER = MARKER,
        BEE_FIXTURE_STREAM = stream("plain.jsonl")}
    worker_data.gateway_tools = {"thread_read", "thread_message"}
    worker_data.agent_launch = {}
    apply(worker)
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
-- Both scripted roles report on the shared thread, each as one stderr notice
-- prefixed "gateway:"; the caller selects the report it asserts against.
local function reports(thread_id: string): {Object}
    local found: {Object} = {}
    for _, item in ipairs(records_of(thread_id)) do
        if item.kind == "observation" and item.source == "stream" then
            local data = (item.body :: Object).data :: Object
            if data.type == "notice" and data.code == "stderr" then
                local text = tostring((data.content :: Object).text)
                local start = text:find("gateway:", 1, true)
                if start then
                    local decoded, err = json.decode(text:sub(start + 8))
                    if err or type(decoded) ~= "table" then error("gateway report unreadable") end
                    found[#found + 1] = decoded :: Object
                end
            end
        end
    end
    return found
end
local function report_with(thread_id: string, field: string): Object
    for _, report in ipairs(reports(thread_id)) do
        if report[field] ~= nil then return report end
    end
    error("no gateway report with " .. field .. " on thread " .. thread_id)
end
local function open_gateway()
    local entry = registry.get("bee:gateway_endpoint")
    if not entry then error("gateway endpoint entry") end
    call("bee.gateway:open", {address = tostring((entry.data :: Object).address)})
end
local function admission(policy_ref: string, thread_id: string, attempt_id: string, workspace_id: string): Object
    local placement = placement_fixture.resolve()
    return {thread_id = thread_id, action_id = "action-" .. attempt_id, attempt_id = attempt_id, owner_id = ACTOR, owner_incarnation = 1, binding_ref = BINDING,
        profile_id = "batch", brief = "orchestrate", policy_ref = policy_ref, workspace_id = workspace_id,
        resources = {{name = "project", grant_ref = "host", root_ref = ROOT, subpath = "", access = "write", purpose = "project"}},
        environment = {}, working_directory = "project", placement_binding_ref = placement.binding_id, placement_binding_digest = placement.binding_digest}
end
local function spawn_carrier(request_value: Object): string
    local pid, err = process.with_context({}):with_actor(actor):with_scope(scope()):spawn_monitored(CARRIER, "bee:workers", request_value, "open", process.pid())
    if not pid then error("spawn carrier: " .. tostring(err)) end
    return tostring(pid)
end
local function await_carrier(pid: string, label: string): Object
    -- spawn_monitored already monitors the carrier, so its exit arrives here.
    local events, events_error = process.events()
    if not events then error(label .. ": events: " .. tostring(events_error)) end
    local deadline = time.after("90s")
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
    test.describe("Agent launch acceptance", function()
        local workspace = fresh("agent-launch-ws")
        local thread_id = fresh("agent-launch-thread")
        test.it("starts an allow-listed child, delivers the brief, and waits for its answer and settlement", function()
            -- Host preparation happens here, not at describe time: an earlier
            -- suite restores the shipped host entries as it finishes.
            prepare_host()
            open_gateway()
            bind_policies()
            call("bee.threads.service:create", {thread_id = thread_id, idempotency_key = thread_id .. "-create", title = "Agent launch acceptance"})
            call("bee.resources.binding:associate", {workspace_id = workspace, name = "project", root_ref = ROOT, subpath = "", allowed_access = "write"})
            call("bee.resources.binding:associate", {workspace_id = workspace, name = "session", root_ref = ROOT, subpath = "", allowed_access = "write"})
            local ok, failure = pcall(function()
            local orchestrator = admission(ORCHESTRATOR_POLICY, thread_id, fresh("orchestrator-attempt"), workspace)
            orchestrator.origin_view = {view_id = "view-agent-origin", instance_id = "instance-agent-origin"}
            orchestrator.environment = {BEE_FIXTURE_GATEWAY = "1", BEE_FIXTURE_GATEWAY_LAUNCH = WORKER_DEFINITION,
                BEE_FIXTURE_GATEWAY_BRIEF = "answer the orchestrator", BEE_FIXTURE_WORKER_MARKER = MARKER, BEE_FIXTURE_STREAM = stream("plain.jsonl")}
            local outcome = await_carrier(spawn_carrier(orchestrator), "orchestrator carrier")
            test.eq((outcome.settlement :: Object).outcome, "succeeded")
            local parent_binding = call("bee.gateway:check", {attempt_id = tostring(orchestrator.attempt_id), carrier_epoch = 1})
            test.eq((parent_binding.origin_view :: Object).view_id, "view-agent-origin")
            test.eq((parent_binding.origin_view :: Object).instance_id, "instance-agent-origin")
            local seen = report_with(thread_id, "launch_ok")
            if seen.launch_ok ~= true then error("orchestrator did not launch the child: " .. tostring(json.encode(seen))) end
            local worker = report_with(thread_id, "worker_posted")
            -- The child runs on the orchestrator's own thread: the bound thread
            -- tools can reach it.
            test.eq(seen.child_thread, thread_id)
            test.eq(seen.child_definition, WORKER_DEFINITION)
            test.eq(seen.child_title, "Agent launch accepted worker")
            test.eq(seen.child_brief, "answer the orchestrator")
            -- The child's own launch policy, not the orchestrator's, decided
            -- what gateway tools the worker held: it read and posted, and the
            -- launch tool its policy does not admit was refused.
            test.eq(worker.worker_read_ok, true)
            test.eq(worker.worker_posted, true)
            test.eq(worker.worker_launch_refused, true)
            local tools = worker.worker_tools :: {string}
            local has_launch = false
            for _, item in ipairs(tools) do if item == "thread_launch" then has_launch = true end end
            test.is_false(has_launch, "the worker was not offered thread_launch")
            -- Lineage: the child action names the orchestrator's action.
            local parent = tostring(seen.child_action)
            local parent_named: string? = nil
            for _, item in ipairs(records_of(thread_id)) do
                if item.kind == "action.admitted" and tostring(item.action_id) == parent then
                    local body = item.body :: Object
                    parent_named = tostring(body.parent_action_id)
                end
            end
            test.not_nil(parent_named, "lineage names the launching action")
            local orchestrator_action = tostring(orchestrator.action_id)
            test.eq(parent_named, orchestrator_action)
            local child_binding = call("bee.gateway:check", {attempt_id = tostring(seen.child_attempt), carrier_epoch = 1})
            test.eq((child_binding.origin_view :: Object).view_id, "view-agent-origin")
            test.eq((child_binding.origin_view :: Object).instance_id, "instance-agent-origin")
            -- The child's answer and terminal receipt are on the thread.
            local kinds: {[string]: boolean} = {}
            local answered = false
            for _, item in ipairs(records_of(thread_id)) do
                kinds[tostring(item.kind)] = true
                if item.kind == "message" then
                    local content = (item.body :: Object).content :: Object
                    if tostring(content.text) == MARKER then answered = true end
                end
            end
            test.is_true(answered, "the worker's answer is on the thread")
            test.is_true(kinds["receipt"] == true, "the child settled a terminal receipt")
            test.is_true(seen.final_marker == true, "the orchestrator's follow-up read saw the child's answer")
            test.is_true(seen.final_receipt == true, "the orchestrator saw the child's own terminal receipt")
            end)
            restore_host()
            if not ok then error(tostring(failure)) end
        end)
    end)
end
return test.run_cases(define_tests)
