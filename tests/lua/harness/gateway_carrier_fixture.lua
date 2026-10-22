-- MIT. The gateway through the carrier and placement with a fixture child
-- that is an actual MCP client: admission after durable preparation,
-- readiness immediately before start, the token minted at delivery into
-- the private home's host-approved configuration and the environment
-- destination, and revocation on child exit, failed startup, carrier
-- loss, listener change, drain and revocation during use.
local shared_authority = require("shared_authority")
local shared_executables = require("shared_executables")
local shared_fixtures = require("shared_fixtures")
local test = require("test")
local bounds = require("bounds")
local principals = require("principals")
local funcs = require("funcs")
local security = require("security")
local process = require("process")
local registry = require("registry")
local env = require("env")
local time = require("time")
local channel = require("channel")
local json = require("json")
local sql = require("sql")
local placement_fixture = require("placement_fixture")
local harness = require("harness")
local ACTOR = "bee.test.gateway_carrier"
local POLICY = "bee.tests.harness:gateway_fixture_policy"
local ROOT = "bee.tests.harness:project_fixture"
local BINDING = "bee.drivers.claude.binding:binding"
local CARRIER = "bee.tests.harness:carrier_faulted"
-- The scripted author's own workspace. The shipped host profiles admit the
-- overlay named by the guide's workspace-application rule; nothing here
-- configures a profile.
local AUTHOR_WORKSPACE = "author-dest-ws"
local SCRIPTED_AUTHOR_TIMEOUT_MS = 90000
type Object = {[string]: unknown}
local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end
local scope_names = {"bee.tests.harness:carrier_client_policy", "bee.tests.harness:gateway_client_policy", "bee.threads.security:create", "bee.threads.security:observe", "bee.threads.security:lifecycle",
    "bee.threads.security:carrier", "bee.harness.security:carrier_policy", "bee.tests.harness:carrier_spawn_policy", "bee.tests.support:gateway_manage_policy", "bee.tests.support:gateway_admit_policy"}
local function scope(): security.Scope
    return shared_authority.scope(scope_names)
end

local function raw_call(target: string, request: unknown, workspace_id: string?): Object
    local selected_workspace = workspace_id or principals.workspace(request)
    local result, err = funcs.new():with_actor(principals.actor(ACTOR, selected_workspace)):with_scope(scope()):call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    return assert(bounds.object(result))
end
local function call(target: string, request: unknown, workspace_id: string?): Object
    local reply = raw_call(target, request, workspace_id)
    if not reply.ok then
        local fault = assert(bounds.object(reply.error))
        error(target .. ": " .. tostring(fault.code) .. ": " .. tostring(fault.message))
    end
    return assert(bounds.object(reply.value))
end
local function code(target: string, request: unknown): string
    local reply = raw_call(target, request)
    if reply.ok then return "OK" end
    return tostring((assert(bounds.object(reply.error))).code)
end
local fixture_bin = shared_executables.fixture_bin

local function stream(name: string): string
    local base, err = env.get("bee.tests.harness:fixture_streams")
    if err or type(base) ~= "string" or base == "" then error("BEE_FIXTURE_STREAMS is not set for the test runtime") end
    return base .. "/claude/stream-json-2/" .. name
end
local function install_policy(name: string)
    local entry = registry.get(name)
    if not entry then error("gateway fixture policy entry " .. name) end
    local data = assert(bounds.object(entry.data))
    data.executables = {claude = fixture_bin() .. "/claude"}
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("install gateway fixture policy: " .. tostring(err)) end
end
local function admit_root()
    -- These runner fixtures exercise host-configured roots with literal grant labels.
    local mode = assert(registry.get("bee.placement.native.env:placement_resource_mode"))
    mode.data = {mode = "host_configured"}
    local selected = registry.snapshot():changes()
    selected:update(mode)
    local configured, mode_error = selected:apply()
    if not configured then error("fixture resource mode: " .. tostring(mode_error)) end
    local entry = registry.get("bee.placement.native.env:placement_admitted_roots")
    if not entry then error("admitted roots entry") end
    local data = assert(bounds.object(entry.data))
    local roots = principals.objects(data.roots)
    data.roots = roots
    for _, root in ipairs(roots) do
        if root.root_ref == ROOT then return end
    end
    roots[#roots + 1] = {root_ref = ROOT, access = "write"}
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("admit root: " .. tostring(err)) end
end
local function endpoint(): string
    local entry = registry.get("bee.gateway.api:gateway_endpoint")
    if not entry then error("gateway endpoint entry") end
    return tostring((assert(bounds.object(entry.data))).address)
end
local function open_gateway(): integer
    local opened = call("bee.gateway.binding:open", {address = endpoint()})
    return math.floor(tonumber(opened.epoch) or 0)
end
local function thread(workspace_id: string?): string
    local created = call("bee.threads.binding:create", {thread_id = fresh("thread"), idempotency_key = fresh("key"), title = "Gateway carrier"}, workspace_id)
    if type(created.thread_id) ~= "string" then error("invalid fixture created.thread_id") end
    return created.thread_id
end
local function request(thread_id: string, attempt_id: string, environment: {[string]: string}, subpath: string?, policy_ref: string?): Object
    local placement = placement_fixture.resolve()
    environment.BEE_FIXTURE_GATEWAY = "1"
    environment.BEE_FIXTURE_REPORT_STREAM = "1"
    if environment.BEE_FIXTURE_STREAM == nil then environment.BEE_FIXTURE_STREAM = stream("plain.jsonl") end
    return {thread_id = thread_id, action_id = "action-" .. attempt_id, attempt_id = attempt_id, owner_id = ACTOR, owner_incarnation = 1, binding_ref = BINDING,
        profile_id = "batch", brief = "ping", policy_ref = policy_ref or POLICY, resources = {{name = "project", grant_ref = "host", root_ref = ROOT, subpath = subpath or "", access = "write", purpose = "project"}},
        environment = environment, working_directory = "project", placement_binding_ref = placement.binding_id,
        placement_binding_digest = placement.binding_digest}
end
type Outcome = {value: Object?, error: string?}
local function spawn_carrier(request_value: Object, mode: string, crash_after: string?, pause_after: string?, fence_controller: string?): string
    local spawner = process.with_context({["bee.test.attach.controller"] = fence_controller}):with_actor(principals.actor(ACTOR, request_value.workspace_id)):with_scope(scope())
    local pid, err = spawner:spawn_monitored(CARRIER, "bee:workers", request_value, mode, process.pid(), crash_after, nil, pause_after)
    if not pid then error("spawn carrier: " .. tostring(err)) end
    return tostring(pid)
end
local exited: {[string]: Outcome} = {}
local function record_exit(event: process.Event)
    if event.kind ~= process.event.EXIT then return end
    local result = event.result or {}
    local value: Object? = nil
    if type(result.value) == "table" then value = assert(bounds.object(result.value)) end
    exited[tostring(event.from)] = {value = value, error = result.error and tostring(result.error) or nil}
end
local function await_exit(pid: string, label: string, timeout_ms: integer?): Outcome
    local events = assert(process.events())
    local deadline = timeout_ms and time.after(tostring(timeout_ms) .. "ms") or nil
    while not exited[pid] do
        local cases = {events:case_receive()}
        if deadline then cases[#cases + 1] = deadline:case_receive() end
        local selected = channel.select(cases)
        if not selected.ok then error(label .. " exit wait interrupted") end
        if deadline and selected.channel == deadline then error(label .. " exceeded the caller's " .. tostring(timeout_ms) .. " ms wait") end
        if selected.value.kind == process.event.CANCEL then error(label .. " exit wait cancelled") end
        record_exit(selected.value)
    end
    return exited[pid]
end
local function run_carrier(request_value: Object, mode: string, crash_after: string?, timeout_ms: integer?): Outcome
    return await_exit(spawn_carrier(request_value, mode, crash_after, nil), mode, timeout_ms)
end
local function continue_carrier(pid: string)
    process.send(pid, "bee.carrier.continue", {})
end
local function await_paused(paused: Channel<process.Message>, pid: string, wanted: string, allow_exit: boolean)
    local events = assert(process.events())
    while not exited[pid] do
        local selected = channel.select({paused:case_receive(), events:case_receive()})
        if not selected.ok then error("carrier pause wait interrupted: " .. pid) end
        if selected.channel == events then
            local event = selected.value
            if event.kind == process.event.CANCEL then error("carrier pause wait cancelled: " .. pid) end
            record_exit(event)
        else
            local message = selected.value
            if tostring(message:from()) == pid and message:payload():data() == wanted then return end
        end
    end
    if not allow_exit then
        error(pid .. " exited before holding at " .. wanted .. ": " .. tostring(exited[pid].error or "completed"))
    end
end
-- After a monitored carrier EXIT its durable stream commits are complete;
-- inspect those records directly, without waiting for an absent producer.
local function records_of(thread_id: string): {Object}
    local all: {Object} = {}
    local cursor = 0
    while true do
        local page = call("bee.threads.binding:read_after", {thread_id = thread_id, cursor = cursor, limit = 64})
        for _, item in ipairs(principals.objects(page.records)) do all[#all + 1] = item end
        if page.has_more ~= true then break end
        local through = bounds.integer(page.scanned_through)
        if not through or through <= cursor then error("fixture record page did not advance its cursor") end
        cursor = through
    end
    return all
end
local function notice(thread_id: string, prefix: string): Object?
    for _, item in ipairs(records_of(thread_id)) do
        if item.kind == "observation" and item.source == "stream" then
            local data = assert(bounds.object((assert(bounds.object(item.body))).data))
            if data.type == "notice" and (data.code == "stderr" or data.code == "informational") then
                local text = tostring((assert(bounds.object(data.content))).text)
                local envelope = json.decode(text)
                if type(envelope) == "table" and type(envelope.content) == "string" then text = envelope.content end
                local start = text:find(prefix, 1, true)
                if start then
                    local decoded, err = json.decode(text:sub(start + #prefix))
                    if err then error(prefix .. " report decode: " .. tostring(err)) end
                    local result = bounds.object(decoded)
                    if not result then error(prefix .. " report must be an object") end
                    return result
                end
            end
        end
    end
    return nil
end
local function report(thread_id: string, attempt_id: string?): Object
    local found = notice(thread_id, "gateway:")
    if found then return found end
    local kinds: {string} = {}
    if attempt_id then
        local page = call("bee.placement.native.binding:evidence", {attempt_id = attempt_id, limit = 128})
        for _, item in ipairs(principals.objects(page.evidence)) do kinds[#kinds + 1] = tostring(item.kind) end
    end
    error("no gateway report in thread " .. thread_id .. "; placement evidence: " .. table.concat(kinds, ","))
end
local function evidence_kinds(attempt_id: string): ({string}, {string})
    local page = call("bee.placement.native.binding:evidence", {attempt_id = attempt_id, limit = 128})
    local names: {string} = {}
    local details: {string} = {}
    for index, item in ipairs(principals.objects(page.evidence)) do
        names[index] = tostring(item.kind)
        details[index] = tostring(item.detail)
    end
    return names, details
end
local has = shared_fixtures.contains

local function detail_with(details: {string}, marker: string): string?
    for _, item in ipairs(details) do
        if item:find(marker, 1, true) then return item end
    end
    return nil
end
-- Placement evidence the runner records on its own schedule; a marker
-- narrows the wait to evidence of that kind whose detail carries it.
local function await_evidence(attempt_id: string, kind: string, marker: string?)
    for _ = 1, 200 do
        local names, details = evidence_kinds(attempt_id)
        for index, name in ipairs(names) do
            if name == kind and (marker == nil or details[index]:find(marker, 1, true)) then return end
        end
        time.sleep("50ms")
    end
    local _, details = evidence_kinds(attempt_id)
    error("evidence " .. kind .. (marker and (" with " .. tostring(marker)) or "") .. " never recorded: " .. table.concat(details, " | "))
end
local function expect_evidence(names: {string}, details: {string}, wanted: string, present: boolean)
    if has(names, wanted) ~= present then error("evidence " .. wanted .. (present and " missing" or " present") .. " in: " .. table.concat(details, " | ")) end
end
local function expect_detail(details: {string}, marker: string, present: boolean)
    if (detail_with(details, marker) ~= nil) ~= present then error("detail " .. marker .. (present and " missing" or " present") .. " in: " .. table.concat(details, " | ")) end
end
local function binding_of(attempt_id: string, carrier_epoch: integer): Object
    return call("bee.gateway.binding:check", {attempt_id = attempt_id, carrier_epoch = carrier_epoch})
end
-- Neither the token nor the one-time materialization key may reach any
-- diagnostic: both are 32 random bytes in base64, so any 44-character
-- base64 run is a leak of one of them.
-- Waits until the child has presented its credential at least the given
-- number of times (initialize, discovery and its first read), so a proof
-- acts on a child that is provably past its first calls whatever the
-- runtime's start latency.
local function await_presented(attempt_id: string, carrier_epoch: integer, wanted: integer)
    for _ = 1, 200 do
        local reply = raw_call("bee.gateway.binding:check", {attempt_id = attempt_id, carrier_epoch = carrier_epoch})
        if reply.ok and (tonumber((assert(bounds.object(reply.value))).presented_count) or 0) >= wanted then return end
        time.sleep("50ms")
    end
    error("the child never presented its credential " .. tostring(wanted) .. " times")
end
-- The fixture child's hook report and the hook records the carrier
-- committed for a thread.
local function hook_report(thread_id: string): Object
    local found = notice(thread_id, "hooks:")
    if not found then error("no hook report in thread " .. thread_id) end
    return found
end
local function hook_records(thread_id: string): {Object}
    local list: {Object} = {}
    for _, item in ipairs(records_of(thread_id)) do
        if item.kind == "observation" and item.source == "bee" then
            local data = assert(bounds.object((assert(bounds.object(item.body))).data))
            if data.event_name == "bee.harness.hook" then
                local payload = assert(bounds.object(json.decode(tostring(data.payload_json))))
                list[#list + 1] = payload
            end
        end
    end
    return list
end
local function no_secret_in(text: string, label: string)
    if text:find("Bearer", 1, true) then error(label .. " carries a bearer value") end
    if text:find("BEE_GATEWAY_TOKEN=", 1, true) then error(label .. " carries the token destination assignment") end
    if text:find("materialization_key", 1, true) then error(label .. " names the materialization key") end
    if text:find("[A-Za-z0-9+/][A-Za-z0-9+/]-[A-Za-z0-9+/]=") and text:find("[A-Za-z0-9+/]" .. string.rep("[A-Za-z0-9+/]", 42) .. "=") then error(label .. " carries a 32-byte base64 secret") end
end
local function no_token_in(details: {string})
    for index, item in ipairs(details) do no_secret_in(item, "evidence " .. tostring(index)) end
end

local function run_cases(define)
    local cases = test.run_cases(define)
    return function(options)
        local roots = assert(registry.get("bee.placement.native.env:placement_admitted_roots"))
        local mode = assert(registry.get("bee.placement.native.env:placement_resource_mode"))
        local ok, result = pcall(cases, options)
        local changes = assert(registry.snapshot()):changes()
        changes:update(roots)
        changes:update(mode)
        assert(changes:apply())
        if not ok then error(tostring(result)) end
        return result
    end
end
return {run_cases = run_cases, ACTOR = ACTOR, POLICY = POLICY, ROOT = ROOT, AUTHOR_WORKSPACE = AUTHOR_WORKSPACE, SCRIPTED_AUTHOR_TIMEOUT_MS = SCRIPTED_AUTHOR_TIMEOUT_MS, fresh = fresh, scope = scope, raw_call = raw_call, call = call, stream = stream, install_policy = install_policy, admit_root = admit_root, open_gateway = open_gateway, thread = thread, request = request, spawn_carrier = spawn_carrier, exited = exited, record_exit = record_exit, await_exit = await_exit, run_carrier = run_carrier, continue_carrier = continue_carrier, await_paused = await_paused, records_of = records_of, report = report, evidence_kinds = evidence_kinds, has = has, detail_with = detail_with, await_evidence = await_evidence, expect_evidence = expect_evidence, expect_detail = expect_detail, binding_of = binding_of, await_presented = await_presented, hook_report = hook_report, hook_records = hook_records, no_secret_in = no_secret_in, no_token_in = no_token_in}
