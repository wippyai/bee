-- MIT. Launch admission against the Claude protocol fixture: a definition
-- resolves to one measured plan with no effects, admission obtains the
-- attempt-bound grant and projection in the requester's own authority,
-- start runs the carrier to settlement, and a retried start recovers the
-- same attempt without a second action, attempt, turn or receipt.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local process = require("process")
local channel = require("channel")
local registry = require("registry")
local env = require("env")
local time = require("time")
local admission = require("admission")
local REQUESTER = "bee.test.launcher"
local DEFINITION = "bee.harness.catalog:fixture_definition"
local POLICY = "bee.harness.catalog:fixture_policy"
local ROOT = "bee.harness.catalog:project_fixture"
local SOURCE = "bee.harness.catalog:launch_sentinel_key"
local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end
local scope_names = {"bee.harness.catalog:launch_client_policy", "bee.harness.catalog:carrier_client_policy", "bee:thread_create_policy", "bee:thread_observe_policy",
    "bee:thread_lifecycle_policy", "bee:thread_carrier_policy", "bee:carrier_policy", "bee.harness.catalog:carrier_spawn_policy", "bee:resource_manage_policy",
    "bee:resource_grant_policy", "bee:credential_manage_policy", "bee:credential_issue_policy", "bee:launch_spawn_policy"}
local function scope(): security.Scope
    local policies: {security.Policy} = {}
    for index, name in ipairs(scope_names) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    return security.new_scope(policies)
end
local actor = security.new_actor(REQUESTER)
local function call(target: string, request: unknown): admission.Reply
    local result, err = funcs.new():with_actor(actor):with_scope(scope()):call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    return result :: admission.Reply
end
local function value(reply: admission.Reply): {[string]: unknown}
    if not reply.ok then error(tostring(reply.error and reply.error.code) .. ": " .. tostring(reply.error and reply.error.message)) end
    return reply.value :: {[string]: unknown}
end
local function code(reply: admission.Reply): string
    if reply.ok then error("expected a failure, got success") end
    return reply.error and reply.error.code or ""
end
local function apply(entry: {[string]: unknown})
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("apply: " .. tostring(err)) end
end
local function fixture_paths(): (string, string)
    local bin, bin_error = env.get("bee.harness.catalog:fixture_bin")
    local streams, streams_error = env.get("bee.harness.catalog:fixture_streams")
    if bin_error or type(bin) ~= "string" or streams_error or type(streams) ~= "string" then error("fixture paths are not set for the test runtime") end
    return bin, streams
end
local function prepare_host(workspace: string)
    local bin, streams = fixture_paths()
    local policy_entry = registry.get(POLICY)
    if not policy_entry then error("fixture policy") end
    local policy_data = policy_entry.data :: {[string]: unknown}
    policy_data.executables = {claude = bin .. "/claude"}
    policy_data.environment = {BEE_FIXTURE_STREAM = streams .. "/claude/stream-json-2/plain.jsonl"}
    apply(policy_entry)
    local roots_entry = registry.get("bee.placement.native:admitted_roots")
    if not roots_entry then error("admitted roots") end
    local roots_data = roots_entry.data :: {[string]: unknown}
    local roots = roots_data.roots :: {{[string]: unknown}}
    local present = false
    for _, root in ipairs(roots) do
        if root.root_ref == ROOT then present = true end
    end
    if not present then
        roots[#roots + 1] = {root_ref = ROOT, access = "write"}
        apply(roots_entry)
    end
    local mode_entry = registry.get("bee.placement.native:resource_mode")
    if not mode_entry then error("resource mode") end
    local mode_data = mode_entry.data :: {[string]: unknown}
    mode_data.mode = "granted"
    apply(mode_entry)
    local sources_entry = registry.get("bee:credential_sources")
    if not sources_entry then error("credential sources") end
    local sources_data = sources_entry.data :: {[string]: unknown}
    local sources = sources_data.sources :: {{[string]: unknown}}
    sources[#sources + 1] = {ref = SOURCE, workspace_id = "*", audience = REQUESTER, provider = "claude", projection_kinds = {"environment"}}
    apply(sources_entry)
    value(call("bee.resources:associate", {workspace_id = workspace, name = "project", root_ref = ROOT, subpath = "", allowed_access = "write"}))
    value(call("bee.credentials:define", {workspace_id = workspace, name = "anthropic", provider = "claude", source = {kind = "env_variable", ref = SOURCE}}))
end
local function restore_host()
    local mode_entry = registry.get("bee.placement.native:resource_mode")
    if not mode_entry then error("resource mode") end
    local mode_data = mode_entry.data :: {[string]: unknown}
    mode_data.mode = "host_configured"
    apply(mode_entry)
end
local function await_exit(pid: string): {[string]: unknown}
    assert(process.monitor(pid))
    local events = assert(process.events())
    local deadline = time.after("30s")
    local outcome: {[string]: unknown}? = nil
    while not outcome do
        local selected = channel.select({events:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then error("carrier did not finish") end
        local event = selected.value
        if event.kind == process.event.EXIT and tostring(event.from) == pid then
            local result = event.result or {}
            if result.error then error("carrier failed: " .. tostring(result.error)) end
            outcome = result.value :: {[string]: unknown}
        end
    end
    return outcome :: {[string]: unknown}
end
local function kinds(thread_id: string): {string}
    local page = value(call("bee.threads.service:read_after", {thread_id = thread_id, cursor = 0, limit = 64}))
    local list: {string} = {}
    for index, item in ipairs(page.records :: {{[string]: unknown}}) do list[index] = tostring(item.kind) end
    return list
end
local function count(list: {string}, wanted: string): integer
    local total = 0
    for _, item in ipairs(list) do
        if item == wanted then total = total + 1 end
    end
    return total
end
local function define_tests()
    test.describe("Launch admission", function()
        local workspace = fresh("ws")
        prepare_host(workspace)
        test.it("resolves a definition to one measured plan without effects", function()
            local plan = value(call("bee.harness.launch:resolve", {definition_ref = DEFINITION}))
            test.eq(plan.launch_id, "claude-fixture")
            test.eq(plan.mode, "batch")
            test.eq(#(plan.plan_digest :: string), 64)
            local again = value(call("bee.harness.launch:resolve", {definition_ref = DEFINITION}))
            test.eq(again.plan_digest, plan.plan_digest)
            test.eq(code(call("bee.harness.launch:resolve", {definition_ref = DEFINITION, mode = "window"})), "FORBIDDEN")
            test.eq(code(call("bee.harness.launch:resolve", {definition_ref = "bee.harness.catalog:nothing"})), "NOT_FOUND")
            local entry = registry.get(DEFINITION)
            if not entry then error("definition") end
            local data = entry.data :: {[string]: unknown}
            local original = data.title
            data.title = "Retitled fixture"
            apply(entry)
            local moved = value(call("bee.harness.launch:resolve", {definition_ref = DEFINITION}))
            test.neq(moved.plan_digest, plan.plan_digest)
            data.title = original
            apply(entry)
        end)
        test.it("admits for the requester, obtaining an attempt-bound grant and projection in the requester's authority", function()
            local request_id = fresh("request")
            local admitted = value(call("bee.harness.launch:admit", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.eq(admitted.requester, REQUESTER)
            test.eq(admitted.attempt_id, "attempt:" .. request_id)
            test.eq(admitted.thread_id, "thread:" .. request_id)
            local carrier_request = admitted.request :: {[string]: unknown}
            test.eq(carrier_request.owner_id, REQUESTER)
            local resources = carrier_request.resources :: {{[string]: unknown}}
            test.eq(#resources, 1)
            test.eq(resources[1].root_ref, ROOT)
            local projections = carrier_request.projections :: {string}
            test.eq(#projections, 1)
            local listed = value(call("bee.credentials:list", {workspace_id = workspace}))
            local found = false
            for _, projection in ipairs(listed.projections :: {{[string]: unknown}}) do
                if projection.projection_id == projections[1] then
                    found = true
                    test.eq(projection.subject, REQUESTER)
                    test.eq(projection.attempt_id, "attempt:" .. request_id)
                end
            end
            test.is_true(found)
            local replay = value(call("bee.harness.launch:admit", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.eq(((replay.request :: {[string]: unknown}).projections :: {string})[1], projections[1])
            test.eq(code(call("bee.harness.launch:admit", {request_id = fresh("request"), definition_ref = DEFINITION, workspace_id = workspace, brief = "ping", thread_id = "t"})), "FORBIDDEN")
            local outsider = funcs.new():with_actor(security.new_actor("bee.test.other")):with_scope(scope())
            local denied, err = outsider:call("bee.harness.launch:admit", {request_id = fresh("request"), definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"})
            if err then error(tostring(err)) end
            test.eq(code(denied :: admission.Reply), "FORBIDDEN")
        end)
        test.it("recovers a start that failed after placement intent and before the first checkpoint", function()
            local request_id = fresh("request")
            local admitted = value(call("bee.harness.launch:admit", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"}))
            local carrier_request = admitted.request :: {[string]: unknown}
            local spawner = process.with_context({}):with_actor(actor):with_scope(scope())
            local crashed_pid, spawn_error = spawner:spawn_monitored("bee.harness.catalog:carrier_faulted", "bee:workers", carrier_request, "open", process.pid(), "placement_intent")
            if not crashed_pid then error("spawn faulted carrier: " .. tostring(spawn_error)) end
            local events = assert(process.events())
            local deadline = time.after("30s")
            local crashed = false
            while not crashed do
                local selected = channel.select({events:case_receive(), deadline:case_receive()})
                if not selected.ok or selected.channel == deadline then error("faulted carrier did not stop") end
                local event = selected.value
                if event.kind == process.event.EXIT and tostring(event.from) == tostring(crashed_pid) then
                    crashed = true
                    if not tostring(event.result and event.result.error):find("crash after placement_intent", 1, true) then error("unexpected end: " .. tostring(event.result and event.result.error)) end
                end
            end
            local before = kinds("thread:" .. request_id)
            test.eq(count(before, "action.admitted"), 1)
            test.eq(count(before, "attempt.prepared"), 1)
            test.eq(count(before, "turn.request"), 0)
            local retried = value(call("bee.harness.launch:start", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.eq(retried.mode, "open")
            local outcome = await_exit(tostring(retried.carrier))
            test.eq((outcome.settlement :: {[string]: unknown}).answer, "pong")
            local after = kinds("thread:" .. request_id)
            test.eq(count(after, "action.admitted"), 1)
            test.eq(count(after, "attempt.prepared"), 1)
            test.eq(count(after, "attempt.started"), 1)
            test.eq(count(after, "turn.request"), 1)
            test.eq(count(after, "receipt"), 1)
        end)
        test.it("starts the carrier to settlement and a retried start recovers the same attempt", function()
            local request_id = fresh("request")
            local started = value(call("bee.harness.launch:start", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.eq(started.mode, "open")
            local outcome = await_exit(tostring(started.carrier))
            test.eq((outcome.settlement :: {[string]: unknown}).answer, "pong")
            local thread_id = tostring(started.thread_id)
            local list = kinds(thread_id)
            test.eq(count(list, "action.admitted"), 1)
            test.eq(count(list, "attempt.prepared"), 1)
            test.eq(count(list, "receipt"), 1)
            test.eq(code(call("bee.harness.launch:start", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"})), "CONFLICT")
            local retried_id = fresh("request")
            local first = value(call("bee.harness.launch:start", {request_id = retried_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"}))
            local first_outcome = await_exit(tostring(first.carrier))
            test.eq((first_outcome.settlement :: {[string]: unknown}).answer, "pong")
            local retried_list = kinds(tostring(first.thread_id))
            test.eq(count(retried_list, "attempt.started"), 1)
            test.eq(count(retried_list, "turn.request"), 1)
        end)
        restore_host()
    end)
end
return test.run_cases(define_tests)
