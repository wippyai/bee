-- MIT. The acceptance for thread_launch through the real MCP surface. A
-- scripted orchestrator agent runs under its own launch policy, which admits
-- thread_launch and allow-lists exactly one worker definition, and it calls
-- thread_launch over the real gateway. The owner operation starts the
-- worker's own managed carrier through the ordinary launch pipeline, the
-- scripted worker reads its thread, posts its answer and settles, and the
-- orchestrator's thread_wait returns. The worker's gateway tools are its own
-- launch policy's, and lineage records the orchestrator's action as parent.
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
local ACTOR = "bee.test.agent_launch_acceptance"
local ORCHESTRATOR_POLICY = "bee.harness.catalog:agent_launch_orchestrator_policy"
local WORKER_POLICY = "bee.harness.catalog:agent_launch_worker_policy"
local WORKER_DEFINITION = "bee.harness.catalog:agent_launch_accepted_worker"
local ROOT = "bee.harness.catalog:project_fixture"
local BINDING = "bee.driver.claude:binding"
local CARRIER = "bee.harness.catalog:carrier_faulted"
local MARKER = "agent-launch-worker-answer"
local LIVE_LONG_MARKER = "bee-long-batch-result-envelope-recorded"
local LONG_DOC_QUERIES = {
    "process lifecycle and independent exit observation",
    "channel selection and backpressure",
    "stdout stream framing and bounded chunks",
    "stderr stream ordering and EOF handling",
    "registry entries and component metadata",
    "SQL transactions and durable records",
    "filesystem roots and workspace grants",
    "HTTP clients and MCP tool requests",
    "event subscriptions and delivery cursors",
    "application manifests and launch contracts",
    "thread membership and owner policy",
    "thread turns and terminal receipts",
    "cross-node subscriptions and hive delivery",
    "placement runner output retention",
    "gateway admission and credential materialization",
    "storage migrations and schema revisions",
    "terminal toolkit layout and measurement",
    "terminal canvas drawing and styles",
    "terminal event input and key decoding",
    "agent launch profiles and allowed tools",
    "carrier checkpoint recovery and replay",
    "process cleanup capabilities and process groups",
    "stream JSON framing and malformed records",
    "provider launch configuration and environment",
    "application approval and activation records",
    "workspace overlays and source inspection",
    "thread wait and child answer delivery",
    "tool result provenance and event envelopes",
    "bounded reads and pagination cursors",
    "runner exit observation and remaining output",
    "carrier settlement and incomplete output",
    "agent corpus topics and stable document identifiers",
}
local LONG_DOC_SEARCHES: {string} = {}
for _, prefix in ipairs({"", "failure modes and recovery for ", "tests and operational limits for "}) do
    for _, query in ipairs(LONG_DOC_QUERIES) do
        LONG_DOC_SEARCHES[#LONG_DOC_SEARCHES + 1] = prefix .. query
    end
end
type Object = {[string]: unknown}
local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end
local scope_names = {"bee.harness.catalog:carrier_client_policy", "bee.harness.catalog:gateway_client_policy", "bee.security.threads:thread_create_policy", "bee.security.threads:thread_observe_policy",
    "bee.security.threads:thread_lifecycle_policy", "bee.security.threads:thread_carrier_policy", "bee.harness.security:carrier_policy", "bee.harness.catalog:carrier_spawn_policy", "bee.security.gateway:gateway_manage_policy", "bee.security.gateway:gateway_admit_policy",
    "bee.resources.security:resource_manage_policy", "bee.credentials.security:credential_manage_policy"}
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
    for _, ref in ipairs({"bee.resources:resource_roots", "bee.placement.native:placement_resource_mode", "bee.placement.native:placement_admitted_roots", "bee.harness:harness_setup", "bee.credentials:credential_sources"}) do
        remember(ref)
    end
    local mode = assert(registry.get("bee.placement.native:placement_resource_mode"))
    mode.data = {mode = "host_configured"}
    apply(mode)
    local roots = assert(registry.get("bee.resources:resource_roots"))
    local roots_data = roots.data :: Object
    local available = roots_data.roots :: {Object}
    local listed = false
    for _, root in ipairs(available) do if root.root_ref == ROOT then listed = true end end
    if not listed then
        available[#available + 1] = {root_ref = ROOT, access = "write"}
        apply(roots)
    end
    local admitted_roots = assert(registry.get("bee.placement.native:placement_admitted_roots"))
    local admitted_data = admitted_roots.data :: Object
    local admitted = admitted_data.roots :: {Object}
    local present = false
    for _, root in ipairs(admitted) do if root.root_ref == ROOT then present = true end end
    if not present then
        admitted[#admitted + 1] = {root_ref = ROOT, access = "write"}
        apply(admitted_roots)
    end
    local setup = assert(registry.get("bee.harness:harness_setup"))
    local setup_data = setup.data :: Object
    setup_data.roots = {project = ROOT, session = ROOT}
    setup_data.credentials = {anthropic = {provider = "claude", source = {kind = "env_variable", ref = "bee.harness.catalog:alternate_setup_key"}}}
    apply(setup)
    local sources = assert(registry.get("bee.credentials:credential_sources"))
    local sources_data = sources.data :: Object
    local list = sources_data.sources :: {Object}
    list[#list + 1] = {ref = "bee.harness.catalog:alternate_setup_key", workspace_id = "*", audience = ACTOR, provider = "claude", projection_kinds = {"environment"}}
    apply(sources)
end
-- The orchestrator runs the fixture executable with the launch instruction in
-- its environment; the worker policy carries the worker instruction, so the
-- child that the real launch pipeline starts is the scripted worker.
local function bind_policies(worker_definition: string?)
    local orchestrator = assert(registry.get(ORCHESTRATOR_POLICY))
    local data = orchestrator.data :: Object
    data.executables = {claude = fixture_bin() .. "/claude"}
    data.environment = {}
    local gateway_tools = {"thread_read", "thread_wait", "thread_launch"}
    if worker_definition then
        local definition = registry.get(worker_definition)
        local definition_data = definition and definition.data :: Object or nil
        local policy_ref = definition_data and type(definition_data.policy_ref) == "string" and definition_data.policy_ref :: string or nil
        local worker_policy = policy_ref and registry.get(policy_ref) or nil
        local policy_data = worker_policy and worker_policy.data :: Object or nil
        local worker_tools = policy_data and policy_data.gateway_tools or nil
        if type(worker_tools) ~= "table" then error("worker gateway tools are unavailable") end
        local seen: {[string]: boolean} = {}
        for _, name in ipairs(gateway_tools) do seen[name] = true end
        for _, name in ipairs(worker_tools :: {unknown}) do
            if type(name) ~= "string" then error("worker gateway tool is invalid") end
            if not seen[name] then
                gateway_tools[#gateway_tools + 1] = name
                seen[name] = true
            end
        end
    end
    data.gateway_tools = gateway_tools
    data.agent_launch = {worker_definition or WORKER_DEFINITION}
    apply(orchestrator)
    local worker = assert(registry.get(WORKER_POLICY))
    local worker_data = worker.data :: Object
    worker_data.executables = {claude = fixture_bin() .. "/claude"}
    worker_data.environment = {BEE_FIXTURE_GATEWAY = "1", BEE_FIXTURE_REPORT_STREAM = "1", BEE_FIXTURE_GATEWAY_WORKER = MARKER, BEE_FIXTURE_WORKER_MARKER = MARKER,
        BEE_FIXTURE_STREAM = stream("plain.jsonl")}
    worker_data.gateway_tools = {"thread_read", "thread_message"}
    worker_data.agent_launch = {}
    apply(worker)
end
local function bind_live_worker(provider: string, worker_definition: string)
    local definition = registry.get(worker_definition)
    local definition_data = definition and definition.data :: Object or nil
    local policy_ref = definition_data and type(definition_data.policy_ref) == "string" and definition_data.policy_ref :: string or nil
    if not policy_ref or policy_ref == "" then
        policy_ref = "bee.driver." .. provider .. ":launch_policy_" .. provider .. "_batch"
    end
    local worker_policy = assert(registry.get(policy_ref))
    local policy_data = worker_policy.data :: Object
    local variable_ref = provider == "claude" and "bee.harness.catalog:live_claude_bin" or "bee.harness.catalog:codex_bin"
    local executable, executable_error = env.get(variable_ref)
    if executable_error or type(executable) ~= "string" or executable == "" then
        error("live " .. provider .. " executable is not configured")
    end
    remember(policy_ref)
    policy_data.executables = {[provider] = executable}
    policy_data.executable_env = {}
    apply(worker_policy)
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
    local guard_ms = math.floor(time.now():unix_nano() / 1000000) + 120000
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
                        if err or type(decoded) ~= "table" then error("gateway report unreadable") end
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
    local deadline_ms = math.floor(time.now():unix_nano() / 1000000) + 5000
    while true do
        local ready, readiness_error = pcall(function()
            return call("bee.gateway.binding:ready", {})
        end)
        if ready then return end
        local detail = tostring(readiness_error)
        if not detail:find("listener answered 404", 1, true) then error(detail) end
        if math.floor(time.now():unix_nano() / 1000000) >= deadline_ms then
            error("gateway /ready route did not become available: " .. detail)
        end
        local retry = time.after("50ms")
        channel.select({retry = retry:case_receive()})
    end
end
local function admission(policy_ref: string, thread_id: string, attempt_id: string, workspace_id: string): Object
    local placement = placement_fixture.resolve()
    return {thread_id = thread_id, action_id = "action-" .. attempt_id, attempt_id = attempt_id, owner_id = ACTOR, owner_incarnation = 1, binding_ref = BINDING,
        profile_id = "batch", brief = "orchestrate", policy_ref = policy_ref, workspace_id = workspace_id,
        resources = {{name = "project", grant_ref = "host", root_ref = ROOT, subpath = "", access = "write", purpose = "project"}},
        environment = {}, working_directory = "project", placement_binding_ref = placement.binding_id, placement_binding_digest = placement.binding_digest}
end
local function spawn_carrier(request_value: Object): string
    local pid, err = process.with_context({}):with_actor(principals.actor(ACTOR, request_value.workspace_id)):with_scope(scope()):spawn_monitored(CARRIER, "bee:workers", request_value, "open", process.pid())
    if not pid then error("spawn carrier: " .. tostring(err)) end
    return tostring(pid)
end
local function await_carrier(pid: string, label: string, timeout_ms: integer?): Object
    -- spawn_monitored already monitors the carrier, so its exit arrives here.
    local events, events_error = process.events()
    if not events then error(label .. ": events: " .. tostring(events_error)) end
    local deadline = time.after(tostring(timeout_ms or 90000) .. "ms")
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
local function long_research_brief(): string
    local lines: {string} = {
        "This is a managed Claude stream transport soak. Do not edit files or use any tool besides the offline Bee docs tool.",
        "Complete all " .. tostring(#LONG_DOC_SEARCHES) .. " numbered items in order. For each item, make exactly one separate Bee docs call with operation=search, offset=0 and limit=4. Wait for its result before moving on. Do not combine searches, skip an item, call another tool, or answer early.",
    }
    for index, query in ipairs(LONG_DOC_SEARCHES) do
        lines[#lines + 1] = tostring(index) .. ". Search documentation about: " .. query
    end
    lines[#lines + 1] = "After all " .. tostring(#LONG_DOC_SEARCHES) .. " separate docs calls, provide no summary. Your final answer must be exactly: " .. LIVE_LONG_MARKER
    return table.concat(lines, "\n")
end
local function run_live_provider(provider: string, long_run: boolean?)
    if provider ~= "claude" and provider ~= "codex" then error("live provider must be claude or codex") end
    local is_long = long_run == true
    local stage = "host setup"
    local ok, failure = pcall(function()
        prepare_host()
        open_gateway()
        local target = "bee.driver." .. provider .. ":research_batch"
        bind_policies(target)
        bind_live_worker(provider, target)
        local setup = assert(registry.get("bee.harness:harness_setup"))
        local setup_data = setup.data :: Object
        local shipped_setup: Object? = nil
        local saved_setup = saved["bee.harness:harness_setup"]
        if type(saved_setup) == "table" then shipped_setup = saved_setup :: Object end
        local shipped_credentials: Object? = nil
        if shipped_setup and type(shipped_setup.credentials) == "table" then
            shipped_credentials = shipped_setup.credentials :: Object
        end
        if not shipped_credentials then error("shipped host credential map is unavailable") end
        setup_data.credentials = copy_of(shipped_credentials)
        apply(setup)

        local thread_id = fresh(is_long and "ambient-provider-long-thread" or "ambient-provider-thread")
        local workspace = fresh("ambient-provider-workspace")
        call("bee.threads.service:create", {thread_id = thread_id, idempotency_key = thread_id .. "-create", title = is_long and "Claude batch envelope soak" or "Ambient provider login smoke"})
        call("bee.resources.binding:associate", {workspace_id = workspace, name = "project", root_ref = ROOT, subpath = "", allowed_access = "write"})
        call("bee.resources.binding:associate", {workspace_id = workspace, name = "session", root_ref = ROOT, subpath = "", allowed_access = "write"})

        local marker = is_long and LIVE_LONG_MARKER or "bee-ambient-provider-login-smoke-ok"
        local orchestrator = admission(ORCHESTRATOR_POLICY, thread_id, fresh("ambient-orchestrator-attempt"), workspace)
        orchestrator.origin_view = {view_id = "view-ambient-login-origin", instance_id = "instance-ambient-login-origin"}
        local orchestrator_environment: Object = {
            BEE_FIXTURE_GATEWAY = "1", BEE_FIXTURE_REPORT_STREAM = "1", BEE_FIXTURE_GATEWAY_LAUNCH = target,
            BEE_FIXTURE_GATEWAY_BRIEF = is_long and long_research_brief() or ("Reply with exactly " .. marker .. " and nothing else."),
            BEE_FIXTURE_WORKER_MARKER = marker, BEE_FIXTURE_STREAM = stream("plain.jsonl"),
        }
        if is_long then orchestrator_environment.BEE_FIXTURE_GATEWAY_LONG_WAIT = "1" end
        orchestrator.environment = orchestrator_environment
        stage = "orchestrator completion"
        local label = is_long and "live Claude long batch" or ("live " .. provider .. " orchestrator")
        local outcome = await_carrier(spawn_carrier(orchestrator), label, is_long and 840000 or 540000)
        stage = "orchestrator settlement"
        if (outcome.settlement :: Object).outcome ~= "succeeded" then error("orchestrator turn did not succeed") end
        stage = "child launch report"
        local seen = report_with(thread_id, "launch_ok")
        if seen.launch_ok ~= true then error("worker launch was refused") end
        stage = "child identity"
        if seen.child_definition ~= target then error("worker definition did not match") end
        stage = "child completion"
        if seen.final_receipt ~= true then error("worker receipt was not observed") end
        if seen.child_outcome ~= "succeeded" then error("worker receipt outcome " .. tostring(seen.child_outcome)) end
        if is_long and seen.final_marker ~= true then error("the terminal result answer was not recorded on the child thread") end
    end)
    restore_host()
    if not ok then
        local label = is_long and "live Claude long batch" or ("live " .. provider .. " smoke")
        local outcome = type(failure) == "string" and failure:match("worker receipt outcome ([%a]+)") or nil
        local suffix = outcome and (" (worker receipt outcome " .. outcome .. ")") or ""
        error(label .. " failed during " .. stage .. suffix)
    end
end
local function define_tests()
    test.describe("Agent launch acceptance", function()
        local workspace = fresh("agent-launch-ws")
        local thread_id = fresh("agent-launch-thread")
        test.it("starts an allow-listed child, delivers the brief, and waits for its answer and settlement", function()
            local live_provider, live_provider_error = env.get("bee.harness.catalog:ambient_live_provider")
            if live_provider_error then error("read live provider test selector: " .. tostring(live_provider_error)) end
            if live_provider == "claude-long" then
                run_live_provider("claude", true)
                return
            end
            if live_provider == "claude" or live_provider == "codex" then
                run_live_provider(live_provider :: string)
                return
            end
            -- Host preparation happens here, not at describe time: an earlier
            -- suite restores the shipped host entries as it finishes.
            prepare_host()
            open_gateway()
            bind_policies(nil)
            call("bee.threads.service:create", {thread_id = thread_id, idempotency_key = thread_id .. "-create", title = "Agent launch acceptance"})
            call("bee.resources.binding:associate", {workspace_id = workspace, name = "project", root_ref = ROOT, subpath = "", allowed_access = "write"})
            call("bee.resources.binding:associate", {workspace_id = workspace, name = "session", root_ref = ROOT, subpath = "", allowed_access = "write"})
            local ok, failure = pcall(function()
            local orchestrator = admission(ORCHESTRATOR_POLICY, thread_id, fresh("orchestrator-attempt"), workspace)
            orchestrator.origin_view = {view_id = "view-agent-origin", instance_id = "instance-agent-origin"}
            orchestrator.environment = {BEE_FIXTURE_GATEWAY = "1", BEE_FIXTURE_REPORT_STREAM = "1", BEE_FIXTURE_GATEWAY_LAUNCH = WORKER_DEFINITION,
                BEE_FIXTURE_GATEWAY_BRIEF = "answer the orchestrator", BEE_FIXTURE_WORKER_MARKER = MARKER, BEE_FIXTURE_STREAM = stream("plain.jsonl")}
            local outcome = await_carrier(spawn_carrier(orchestrator), "orchestrator carrier")
            test.eq((outcome.settlement :: Object).outcome, "succeeded")
            local parent_binding = call("bee.gateway.binding:check", {attempt_id = tostring(orchestrator.attempt_id), carrier_epoch = 1})
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
            local child_binding = call("bee.gateway.binding:check", {attempt_id = tostring(seen.child_attempt), carrier_epoch = 1})
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
