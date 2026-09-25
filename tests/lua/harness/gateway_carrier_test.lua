-- MIT. The gateway through the carrier and placement with a fixture child
-- that is an actual MCP client: admission after durable preparation,
-- readiness immediately before start, the token minted at delivery into
-- the private home's host-approved configuration and the environment
-- destination, and revocation on child exit, failed startup, carrier
-- loss, listener change, drain and revocation during use.
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
local ACTOR = "bee.test.gateway_carrier"
local POLICY = "bee.harness.catalog:gateway_fixture_policy"
local EXPIRING_POLICY = "bee.harness.catalog:gateway_expiring_policy"
local ROOT = "bee.harness.catalog:project_fixture"
local BINDING = "bee.driver.claude:binding"
local CARRIER = "bee.harness.catalog:carrier_faulted"
-- The scripted author's own workspace. The shipped host profiles admit the
-- overlay named by the guide's workspace-application rule; nothing here
-- configures a profile.
local AUTHOR_WORKSPACE = "author-dest-ws"
type Object = {[string]: unknown}
local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end
local scope_names = {"bee.harness.catalog:carrier_client_policy", "bee.harness.catalog:gateway_client_policy", "bee.security.threads:thread_create_policy", "bee.security.threads:thread_observe_policy", "bee.security.threads:thread_lifecycle_policy",
    "bee.security.threads:thread_carrier_policy", "bee.security.harness:carrier_policy", "bee.harness.catalog:carrier_spawn_policy", "bee.security.gateway:gateway_manage_policy", "bee.security.gateway:gateway_admit_policy"}
local function scope(): security.Scope
    local policies: {security.Policy} = {}
    for index, name in ipairs(scope_names) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    return security.new_scope(policies)
end
local function raw_call(target: string, request: unknown): Object
    local result, err = funcs.new():with_actor(principals.actor(ACTOR, principals.workspace(request))):with_scope(scope()):call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    return result :: Object
end
local function call(target: string, request: unknown): Object
    local reply = raw_call(target, request)
    if not reply.ok then
        local fault = reply.error :: Object
        error(target .. ": " .. tostring(fault.code) .. ": " .. tostring(fault.message))
    end
    return reply.value :: Object
end
local function code(target: string, request: unknown): string
    local reply = raw_call(target, request)
    if reply.ok then return "OK" end
    return tostring((reply.error :: Object).code)
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
local function install_policy(name: string)
    local entry = registry.get(name)
    if not entry then error("gateway fixture policy entry " .. name) end
    local data = entry.data :: Object
    data.executables = {claude = fixture_bin() .. "/claude"}
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("install gateway fixture policy: " .. tostring(err)) end
end
local function admit_root()
    -- These runner fixtures exercise host-configured roots with literal grant labels.
    local mode = assert(registry.get("bee:placement_resource_mode"))
    mode.data = {mode = "host_configured"}
    local selected = registry.snapshot():changes()
    selected:update(mode)
    local configured, mode_error = selected:apply()
    if not configured then error("fixture resource mode: " .. tostring(mode_error)) end
    local entry = registry.get("bee:placement_admitted_roots")
    if not entry then error("admitted roots entry") end
    local data = entry.data :: Object
    local roots = data.roots :: {Object}
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
    local entry = registry.get("bee:gateway_endpoint")
    if not entry then error("gateway endpoint entry") end
    return tostring((entry.data :: Object).address)
end
local function open_gateway(): integer
    local opened = call("bee.gateway.binding:open", {address = endpoint()})
    return math.floor(tonumber(opened.epoch) or 0)
end
local function thread(): string
    local created = call("bee.threads.service:create", {thread_id = fresh("thread"), idempotency_key = fresh("key"), title = "Gateway carrier"})
    return created.thread_id :: string
end
local function request(thread_id: string, attempt_id: string, environment: {[string]: string}, subpath: string?, policy_ref: string?): Object
    local placement = placement_fixture.resolve()
    environment.BEE_FIXTURE_GATEWAY = "1"
    if environment.BEE_FIXTURE_STREAM == nil then environment.BEE_FIXTURE_STREAM = stream("plain.jsonl") end
    return {thread_id = thread_id, action_id = "action-" .. attempt_id, attempt_id = attempt_id, owner_id = ACTOR, owner_incarnation = 1, binding_ref = BINDING,
        profile_id = "batch", brief = "ping", policy_ref = policy_ref or POLICY, resources = {{name = "project", grant_ref = "host", root_ref = ROOT, subpath = subpath or "", access = "write", purpose = "project"}},
        environment = environment, working_directory = "project", placement_binding_ref = placement.binding_id,
        placement_binding_digest = placement.binding_digest}
end
type Outcome = {value: Object?, error: string?}
local function spawn_carrier(request_value: Object, mode: string, crash_after: string?, pause_after: string?): string
    local spawner = process.with_context({}):with_actor(principals.actor(ACTOR, request_value.workspace_id)):with_scope(scope())
    local pid, err = spawner:spawn_monitored(CARRIER, "bee:workers", request_value, mode, process.pid(), crash_after, nil, pause_after)
    if not pid then error("spawn carrier: " .. tostring(err)) end
    return tostring(pid)
end
local exited: {[string]: Outcome} = {}
local function record_exit(event: process.Event)
    if event.kind ~= process.event.EXIT then return end
    local result = event.result or {}
    local value: Object? = nil
    if type(result.value) == "table" then value = result.value :: Object end
    exited[tostring(event.from)] = {value = value, error = result.error and tostring(result.error) or nil}
end
local function await_carrier(pid: string, label: string): Outcome
    local events = assert(process.events())
    local deadline = time.after("40s")
    while not exited[pid] do
        local selected = channel.select({events:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then error(label .. " did not finish") end
        record_exit(selected.value)
    end
    return exited[pid] :: Outcome
end
local function run_carrier(request_value: Object, mode: string, crash_after: string?): Outcome
    return await_carrier(spawn_carrier(request_value, mode, crash_after, nil), mode)
end
local function continue_carrier(pid: string)
    process.send(pid, "bee.carrier.continue", {})
end
-- Waits for the carrier's report that it holds at the named step. The
-- caller listens for bee.carrier.paused before spawning the carrier.
local function await_paused(paused: Channel<process.Message>, pid: string, wanted: string)
    local deadline = time.after("30s")
    while true do
        local selected = channel.select({paused:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then error(pid .. " never held at " .. wanted) end
        local message = selected.value
        if tostring(message:from()) == pid and message:payload():data() == wanted then return end
    end
end
-- Waits until the carrier either holds at the named step or ends; its exit
-- is recorded for await_carrier.
local function await_paused_or_exit(paused: Channel<process.Message>, pid: string, wanted: string)
    local events = assert(process.events())
    local deadline = time.after("30s")
    while not exited[pid] do
        local selected = channel.select({paused:case_receive(), events:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then error(pid .. " neither held at " .. wanted .. " nor ended") end
        if selected.channel == events then
            record_exit(selected.value)
        else
            local message = selected.value
            if tostring(message:from()) == pid and message:payload():data() == wanted then return end
        end
    end
end
-- The fixture child's report, one stderr line the carrier records as a notice.
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
local function report(thread_id: string, attempt_id: string?): Object
    for _, item in ipairs(records_of(thread_id)) do
        if item.kind == "observation" and item.source == "stream" then
            local data = (item.body :: Object).data :: Object
            if data.type == "notice" and data.code == "stderr" then
                local text = tostring((data.content :: Object).text)
                local start = text:find("gateway:", 1, true)
                if start then
                    local decoded, err = json.decode(text:sub(start + 8))
                    if err or type(decoded) ~= "table" then error("gateway report unreadable: " .. text) end
                    return decoded :: Object
                end
            end
        end
    end
    local kinds: {string} = {}
    if attempt_id then
        local page = call("bee.placement.native.binding:evidence", {attempt_id = attempt_id, limit = 128})
        for _, item in ipairs(page.evidence :: {Object}) do kinds[#kinds + 1] = tostring(item.kind) end
    end
    error("no gateway report in thread " .. thread_id .. "; placement evidence: " .. table.concat(kinds, ","))
end
local function evidence_kinds(attempt_id: string): ({string}, {string})
    local page = call("bee.placement.native.binding:evidence", {attempt_id = attempt_id, limit = 128})
    local names: {string} = {}
    local details: {string} = {}
    for index, item in ipairs(page.evidence :: {Object}) do
        names[index] = tostring(item.kind)
        details[index] = tostring(item.detail)
    end
    return names, details
end
local function has(list: {string}, wanted: string): boolean
    for _, item in ipairs(list) do
        if item == wanted then return true end
    end
    return false
end
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
            if name == kind and (marker == nil or details[index]:find(marker :: string, 1, true)) then return end
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
        if reply.ok and (tonumber((reply.value :: Object).presented_count) or 0) >= wanted then return end
        time.sleep("50ms")
    end
    error("the child never presented its credential " .. tostring(wanted) .. " times")
end
-- The fixture child's hook report and the hook records the carrier
-- committed for a thread.
local function hook_report(thread_id: string): Object
    for _, item in ipairs(records_of(thread_id)) do
        if item.kind == "observation" and item.source == "stream" then
            local data = (item.body :: Object).data :: Object
            if data.type == "notice" and data.code == "stderr" then
                local text = tostring((data.content :: Object).text)
                local start = text:find("hooks:", 1, true)
                if start then
                    local decoded, err = json.decode(text:sub(start + 6))
                    if err or type(decoded) ~= "table" then error("hook report unreadable: " .. text) end
                    return decoded :: Object
                end
            end
        end
    end
    error("no hook report in thread " .. thread_id)
end
local function hook_records(thread_id: string): {Object}
    local list: {Object} = {}
    for _, item in ipairs(records_of(thread_id)) do
        if item.kind == "observation" and item.source == "bee" then
            local data = (item.body :: Object).data :: Object
            if data.event_name == "bee.harness.hook" then
                local payload = json.decode(tostring(data.payload_json)) :: Object
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
local function define_tests()
    test.describe("Gateway through the carrier", function()
        install_policy(POLICY)
        install_policy(EXPIRING_POLICY)
        install_policy("bee.harness.catalog:gateway_surface_policy")
        admit_root()
        open_gateway()
        test.it("admits after preparation, projects the token at delivery, serves the child as an MCP client and revokes on exit", function()
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local outcome = run_carrier(request(thread_id, attempt_id, {}), "open", nil)
            if not outcome.value then error("carrier failed: " .. tostring(outcome.error)) end
            test.eq((outcome.value.settlement :: Object).outcome, "succeeded")
            local seen = report(thread_id)
            test.eq(seen.initialize, 200)
            test.eq(seen.protocol, "2025-06-18")
            test.eq(seen.list, 200)
            test.eq(json.encode(seen.tools), json.encode({"call_tool", "session", "thread_read", "thread_wait"}))
            test.eq(seen.read, 200)
            test.eq(seen.read_ok, true)
            local names, details = evidence_kinds(attempt_id)
            expect_evidence(names, details, "gateway.materialized", true)
            expect_evidence(names, details, "gateway.sealed", true)
            expect_evidence(names, details, "carrier.lost", false)
            expect_detail(details, "credential generation 1 under carrier epoch 1", true)
            expect_detail(details, "child exited; binding", true)
            no_token_in(details)
            local binding = binding_of(attempt_id, 1)
            test.eq(binding.valid, false)
            test.eq(binding.reason, "binding is revoked")
            test.eq(binding.credential_generation, 1)
        end)
        test.it("delivers configured traits and bounded context to the managed MCP child", function()
            local thread_id = thread()
            local result = run_carrier(request(thread_id, fresh("surface"), {BEE_FIXTURE_GATEWAY_SURFACE = "1"}, nil,
                "bee.harness.catalog:gateway_surface_policy"), "open", nil)
            if not result.value then error("configured carrier failed: " .. tostring(result.error)) end
            test.eq((result.value.settlement :: Object).outcome, "succeeded")
            local seen = report(thread_id)
            test.eq(json.encode(seen.tools), json.encode({"call_tool", "session", "thread_read"}))
            test.eq((seen.surface_inactive :: Object).code, -32602)
            test.eq((seen.surface_selected :: Object).ok, true)
            local current = (seen.surface_after :: Object).value :: Object
            test.eq(current.revision, 2)
            test.eq(json.encode(current.active_traits), json.encode({"research:read", "research:wait"}))
            test.eq((current.context :: Object).experiment, "managed-one")
            test.eq((seen.surface_dispatch :: Object).ok, true)
            test.eq((seen.surface_overwrite :: Object).ok, false)
        end)
        test.it("replays the binding whose carrier was lost before projection and starts under it on retry", function()
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local launch = request(thread_id, attempt_id, {})
            local crashed = run_carrier(launch, "open", "gateway_admitted")
            test.is_nil(crashed.value)
            test.is_true(tostring(crashed.error):find("crash after gateway_admitted", 1, true) ~= nil)
            local before = binding_of(attempt_id, 1)
            test.eq(before.valid, true)
            test.eq(before.credential_generation, 0)
            -- The retry claims the same carrier epoch and admits the same
            -- identity, so the binding replays rather than multiplies; its
            -- first credential generation is minted at the retry's delivery.
            local retried = run_carrier(launch, "open", nil)
            if not retried.value then error("retried carrier failed: " .. tostring(retried.error)) end
            test.eq((retried.value.settlement :: Object).outcome, "succeeded")
            local replayed = call("bee.gateway.binding:check", {binding_id = before.binding_id})
            test.eq(replayed.credential_generation, 1)
            test.eq(replayed.valid, false)
            test.eq(replayed.reason, "binding is revoked")
            local seen = report(thread_id)
            test.eq(seen.read, 200)
            local names, details = evidence_kinds(attempt_id)
            expect_evidence(names, details, "gateway.materialized", true)
            expect_detail(details, "binding " .. tostring(before.binding_id) .. " credential generation 1", true)
        end)
        test.it("revokes a projected token when the child never starts", function()
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            -- The working directory is a subpath the project root does not
            -- hold, so the executor refuses the start after the token was
            -- materialized into the environment.
            local outcome = run_carrier(request(thread_id, attempt_id, {}, "absent-directory"), "open", nil)
            test.is_nil(outcome.value)
            if not tostring(outcome.error):find("bee.placement.native.binding:start", 1, true) then error("unexpected refusal: " .. tostring(outcome.error)) end
            -- The runner held the materialization key and the token when it
            -- refused; neither reaches the carrier's error nor the records.
            no_secret_in(tostring(outcome.error), "carrier error")
            for _, item in ipairs(records_of(thread_id)) do no_secret_in(json.encode(item), "thread record") end
            local names, details = evidence_kinds(attempt_id)
            expect_evidence(names, details, "gateway.materialized", true)
            expect_evidence(names, details, "gateway.revoked", true)
            expect_detail(details, "start refused", true)
            expect_evidence(names, details, "child.exited", false)
            no_token_in(details)
            local status = call("bee.placement.native.binding:status", {attempt_id = attempt_id})
            test.eq((status.attempt :: Object).execution_state, "exited")
            local binding = binding_of(attempt_id, 1)
            test.eq(binding.valid, false)
            test.eq(binding.reason, "binding is revoked")
        end)
        test.it("refuses the start when the listener generation changes between readiness and start", function()
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local paused = assert(process.listen("bee.carrier.paused", {message = true}))
            local pid = spawn_carrier(request(thread_id, attempt_id, {}), "open", nil, "gateway_ready")
            await_paused(paused, pid, "gateway_ready")
            process.unlisten(paused)
            open_gateway()
            continue_carrier(pid)
            local outcome = await_carrier(pid, "paused carrier")
            test.is_nil(outcome.value)
            test.is_true(tostring(outcome.error):find("earlier listener epoch", 1, true) ~= nil)
            local names, details = evidence_kinds(attempt_id)
            if not has(names, "gateway.refused") then error("evidence gateway.refused missing; carrier error: " .. tostring(outcome.error) .. "; evidence: " .. table.concat(details, " | ")) end
            expect_detail(details, "earlier listener epoch", true)
            expect_evidence(names, details, "gateway.materialized", false)
            expect_evidence(names, details, "child.exited", false)
            -- The failed startup revokes the binding; nothing was ever minted.
            local binding = binding_of(attempt_id, 1)
            test.eq(binding.valid, false)
            test.eq(binding.reason, "binding is revoked")
            test.eq(binding.credential_generation, 0)
        end)
        test.it("retires the binding when the carrier is lost and no replacement takes over within the grace", function()
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local launch = request(thread_id, attempt_id, {BEE_FIXTURE_GATEWAY_HOLD = "stop"})
            local pid = spawn_carrier(launch, "open", nil, "attempt_started")
            await_presented(attempt_id, 1, 3)
            local live = binding_of(attempt_id, 1)
            test.eq(live.valid, true)
            assert(process.terminate(pid), "terminate carrier")
            await_carrier(pid, "terminated carrier")
            -- Once the runner has observed the loss, the child keeps its token
            -- within the takeover grace.
            await_evidence(attempt_id, "carrier.lost")
            local kept = binding_of(attempt_id, 1)
            test.eq(kept.valid, true)
            await_evidence(attempt_id, "gateway.revoked", "no takeover")
            local lost = binding_of(attempt_id, 1)
            test.eq(lost.valid, false)
            test.eq(lost.reason, "binding is revoked")
            -- The child holds until the enforcement path stops it, so it
            -- presents its token again only after the retirement.
            call("bee.placement.native.binding:reconcile", {attempt_id = attempt_id})
            local resumed = run_carrier(launch, "resume", nil)
            if not resumed.value then error("resumed carrier failed: " .. tostring(resumed.error)) end
            local seen = report(thread_id)
            test.eq(seen.read, 200)
            test.eq(seen.after_hold, 401)
            local names, details = evidence_kinds(attempt_id)
            expect_evidence(names, details, "carrier.lost", true)
            expect_detail(details, "lost under generation 1; no takeover", true)
            no_token_in(details)
        end)
        test.it("records a carrier lost after its child exited, whichever the runner observes first", function()
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local launch = request(thread_id, attempt_id, {})
            local pid = spawn_carrier(launch, "open", nil, "attempt_started")
            -- The child ends on its own while the carrier holds, so the runner
            -- has observed its exit before the carrier is terminated.
            await_presented(attempt_id, 1, 3)
            await_evidence(attempt_id, "child.exited")
            assert(process.terminate(pid), "terminate carrier")
            await_carrier(pid, "terminated carrier")
            await_evidence(attempt_id, "carrier.lost")
            local resumed = run_carrier(launch, "resume", nil)
            if not resumed.value then error("resumed carrier failed: " .. tostring(resumed.error)) end
            test.eq((resumed.value.settlement :: Object).outcome, "succeeded")
            test.eq(report(thread_id, attempt_id).read, 200)
            local names, details = evidence_kinds(attempt_id)
            expect_evidence(names, details, "carrier.replaced", true)
            no_token_in(details)
        end)
        test.it("keeps the child's token across a takeover and ignores the old carrier's delayed exit", function()
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local launch = request(thread_id, attempt_id, {BEE_FIXTURE_GATEWAY_HOLD = "4"})
            local old = spawn_carrier(launch, "open", nil, "attempt_started")
            await_presented(attempt_id, 1, 3)
            local replacement = spawn_carrier(launch, "resume", nil, nil)
            -- Once the runner has installed generation 2 it no longer monitors
            -- the old carrier, whose exit then revokes nothing.
            await_evidence(attempt_id, "attach.fenced", "runner installed generation 2")
            assert(process.terminate(old), "terminate old carrier")
            await_carrier(old, "old carrier")
            local inherited = binding_of(attempt_id, 2)
            test.eq(inherited.valid, true)
            test.eq(inherited.carrier_epoch, 1)
            local outcome = await_carrier(replacement, "replacement carrier")
            if not outcome.value then error("replacement carrier failed: " .. tostring(outcome.error)) end
            test.eq(outcome.value.epoch, 2)
            local seen = report(thread_id)
            test.eq(seen.read, 200)
            test.eq(seen.after_hold, 200)
            local names, details = evidence_kinds(attempt_id)
            expect_detail(details, "runner installed generation 2", true)
            expect_evidence(names, details, "carrier.lost", false)
            expect_detail(details, "no takeover", false)
            -- Settlement under the replacement retires the inherited binding.
            local settled = binding_of(attempt_id, 2)
            test.eq(settled.valid, false)
            test.eq(settled.reason, "binding is revoked")
            no_token_in(details)
        end)
        -- Inside the takeover grace the binding is alive only for a takeover;
        -- an explicit revocation, a listener reopen and the binding's own
        -- expiry each take effect at once.
        local function lose_carrier_then(policy_ref: string?, act: (string) -> ()): Object
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local launch = request(thread_id, attempt_id, {BEE_FIXTURE_GATEWAY_HOLD = "stop"}, nil, policy_ref)
            local pid = spawn_carrier(launch, "open", nil, "attempt_started")
            await_presented(attempt_id, 1, 3)
            assert(process.terminate(pid), "terminate carrier")
            await_carrier(pid, "terminated carrier")
            await_evidence(attempt_id, "carrier.lost")
            act(attempt_id)
            -- Force the real enforcement path instead of racing the periodic
            -- sweeper. The fixture must still report an actual HTTP denial.
            call("bee.placement.native.binding:reconcile", {attempt_id = attempt_id})
            local resumed = run_carrier(launch, "resume", nil)
            if not resumed.value then error("resumed carrier failed: " .. tostring(resumed.error)) end
            local seen = report(thread_id, attempt_id)
            test.eq(seen.read, 200)
            local names, details = evidence_kinds(attempt_id)
            expect_evidence(names, details, "carrier.lost", true)
            expect_evidence(names, details, "gateway.revoked", true)
            expect_evidence(names, details, "stop.requested", true)
            no_token_in(details)
            return seen
        end
        test.it("refuses a token revoked inside the takeover grace at once", function()
            local seen = lose_carrier_then(nil, function(attempt_id: string)
                local live = binding_of(attempt_id, 1)
                test.eq(live.valid, true)
                call("bee.gateway.binding:revoke", {binding_id = live.binding_id})
            end)
            test.eq(seen.after_hold, 401)
        end)
        test.it("refuses a token whose listener generation changed inside the takeover grace at once", function()
            local seen = lose_carrier_then(nil, function(attempt_id: string)
                test.eq(binding_of(attempt_id, 1).valid, true)
                open_gateway()
            end)
            test.eq(seen.after_hold, 401)
        end)
        test.it("refuses a token that expires inside the takeover grace at once", function()
            local seen = lose_carrier_then(EXPIRING_POLICY, function(attempt_id: string)
                test.eq(binding_of(attempt_id, 1).valid, true)
                -- The binding expires 2.5 s after its admission; the poll
                -- outlasts that by a margin whatever the runtime's load.
                local expired = binding_of(attempt_id, 1)
                for _ = 1, 160 do
                    if expired.valid == false then break end
                    time.sleep("50ms")
                    expired = binding_of(attempt_id, 1)
                end
                test.eq(expired.valid, false)
                test.eq(expired.reason, "binding has expired")
            end)
            test.eq(seen.after_hold, 401)
        end)
        test.it("commits the child's hooks as records through its own commit path and keeps content out", function()
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local outcome = run_carrier(request(thread_id, attempt_id, {BEE_FIXTURE_HOOKS = "1"}), "open", nil)
            if not outcome.value then error("carrier failed: " .. tostring(outcome.error)) end
            test.eq((outcome.value.settlement :: Object).outcome, "succeeded")
            local reported = hook_report(thread_id)
            test.eq(json.encode(reported.statuses), json.encode({202, 202, 202, 202, 202}))
            -- The carrier can commit the first occurrence before the child
            -- replays it: queued replay is 202, committed replay is 200.
            -- The records and final queue below still prove exactly one commit.
            test.is_true(reported.replay == 202 or reported.replay == 200)
            test.eq(reported.bodies_empty, true)
            local committed = hook_records(thread_id)
            local by_event: {[string]: integer} = {}
            for _, payload in ipairs(committed) do by_event[tostring(payload.event)] = (by_event[tostring(payload.event)] or 0) + 1 end
            for _, event in ipairs({"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"}) do
                if by_event[event] ~= 1 then error("hook " .. event .. " committed " .. tostring(by_event[event]) .. " times") end
            end
            local text = json.encode(committed) or ""
            test.is_nil(text:find("sk-fixture", 1, true))
            test.is_nil(text:find("the brief", 1, true))
            test.is_nil(text:find("decision", 1, true))
            test.is_true(text:find("content_digests", 1, true) ~= nil)
            local binding = binding_of(attempt_id, 1)
            test.eq(binding.reason, "binding is revoked")
            local queue = call("bee.gateway.binding:hook_queue", {binding_id = binding.binding_id})
            for _, item in ipairs(queue.hooks :: {Object}) do test.eq(item.status, "committed") end
            no_token_in({text})
        end)
        test.it("recovers a crash between the hook commit and its acknowledgment without a duplicate record", function()
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local launch = request(thread_id, attempt_id, {BEE_FIXTURE_HOOKS = "1", BEE_FIXTURE_LINGER = "1"})
            local crashed = run_carrier(launch, "open", "hooks_committed")
            test.is_nil(crashed.value)
            test.is_true(tostring(crashed.error):find("crash after hooks_committed", 1, true) ~= nil)
            local resumed = run_carrier(launch, "resume", nil)
            if not resumed.value then error("resumed carrier failed: " .. tostring(resumed.error)) end
            test.eq((resumed.value.settlement :: Object).outcome, "succeeded")
            local committed = hook_records(thread_id)
            local seen: {[string]: integer} = {}
            for _, payload in ipairs(committed) do
                local key = tostring(payload.event) .. ":" .. tostring(payload.occurrence)
                seen[key] = (seen[key] or 0) + 1
            end
            for key, count in pairs(seen) do
                if count ~= 1 then error("hook " .. key .. " committed " .. tostring(count) .. " times after the crash") end
            end
            local binding = binding_of(attempt_id, 2)
            local queue = call("bee.gateway.binding:hook_queue", {binding_id = binding.binding_id})
            for _, item in ipairs(queue.hooks :: {Object}) do
                if item.status == "queued" then error("a queued hook survived settlement: " .. tostring(item.event)) end
            end
        end)
        test.it("answers overload while the carrier is not draining and commits every accepted submission once it drains", function()
            -- The carrier is held right after the attempt starts, so nothing
            -- drains while the child floods; the queue fills to its bound, the
            -- child receives 429 past it, and once the carrier continues every
            -- accepted row ends committed.
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local pid = spawn_carrier(request(thread_id, attempt_id, {BEE_FIXTURE_HOOKS = "1", BEE_FIXTURE_HOOKS_FLOOD = "80"}), "open", nil, "attempt_started")
            local binding_id = ""
            for _ = 1, 200 do
                local reply = raw_call("bee.gateway.binding:check", {attempt_id = attempt_id, carrier_epoch = 1})
                if reply.ok then
                    binding_id = tostring((reply.value :: Object).binding_id)
                    local queue = call("bee.gateway.binding:hook_queue", {binding_id = binding_id})
                    local queued = 0
                    for _, item in ipairs(queue.hooks :: {Object}) do
                        if item.status == "queued" then queued = queued + 1 end
                    end
                    if queued >= 64 then break end
                end
                time.sleep("50ms")
            end
            test.neq(binding_id, "")
            continue_carrier(pid)
            local outcome = await_carrier(pid, "flooded carrier")
            if not outcome.value then error("carrier failed: " .. tostring(outcome.error)) end
            local reported = hook_report(thread_id)
            local flood = reported.flood :: Object
            local accepted = (tonumber(flood["202"]) or 0)
            local refused = (tonumber(flood["429"]) or 0)
            test.eq(accepted + refused, 80)
            test.is_true(refused > 0)
            local committed = 0
            for _, payload in ipairs(hook_records(thread_id)) do
                if tostring(payload.occurrence):find("toolu_flood_", 1, true) then committed = committed + 1 end
            end
            test.eq(committed, accepted)
            local queue = call("bee.gateway.binding:hook_queue", {binding_id = binding_id})
            for _, item in ipairs(queue.hooks :: {Object}) do
                if item.status == "queued" then error("a queued row survived: " .. tostring(item.occurrence)) end
            end
        end)
        -- Two live carriers on one queue: the replacement takes the rows over
        -- at its claim, and the fenced original can neither commit nor
        -- acknowledge them afterwards.
        local function two_carriers(pause_at: string)
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local launch = request(thread_id, attempt_id, {BEE_FIXTURE_HOOKS = "1", BEE_FIXTURE_GATEWAY_HOLD = "3"})
            local paused = assert(process.listen("bee.carrier.paused", {message = true}))
            -- An original held after its commit holds again once its
            -- acknowledgment call returns.
            local pauses = pause_at
            if pause_at == "hooks_committed" then pauses = "hooks_committed,hooks_acknowledged" end
            local old = spawn_carrier(launch, "open", nil, pauses)
            await_paused(paused, old, pause_at)
            local replacement = spawn_carrier(launch, "resume", nil, nil)
            local outcome = await_carrier(replacement, "replacement carrier")
            if not outcome.value then error("replacement carrier failed: " .. tostring(outcome.error)) end
            continue_carrier(old)
            -- An original held after its commit acknowledges nothing the
            -- replacement claimed; it then holds after that call or ends on its
            -- next refused commit, and is stopped once either is observed. One
            -- held before its commit is refused at the commit and ends on its
            -- own.
            local fenced: Outcome
            if pause_at == "hooks_committed" then
                await_paused_or_exit(paused, old, "hooks_acknowledged")
                -- Cleanup may race the fenced carrier's own exit. The monitored
                -- EXIT below is the proof it stopped, not terminate's return.
                process.terminate(old)
            end
            process.unlisten(paused)
            fenced = await_carrier(old, "fenced carrier")
            test.is_nil(fenced.value)
            local committed = hook_records(thread_id)
            local seen: {[string]: integer} = {}
            for _, payload in ipairs(committed) do
                local key = tostring(payload.event) .. ":" .. tostring(payload.occurrence)
                seen[key] = (seen[key] or 0) + 1
            end
            for key, count in pairs(seen) do
                if count ~= 1 then error("hook " .. key .. " committed " .. tostring(count) .. " times across two carriers") end
            end
            test.is_true(seen["PreToolUse:tool:toolu_fixture_1"] == 1)
            local binding = binding_of(attempt_id, 2)
            local queue = call("bee.gateway.binding:hook_queue", {binding_id = binding.binding_id})
            for _, item in ipairs(queue.hooks :: {Object}) do
                if item.status == "queued" then error("a queued row survived the takeover: " .. tostring(item.occurrence)) end
                if item.status == "committed" and item.claimed_epoch ~= 2 then error("a row was acknowledged by an epoch that did not claim it: " .. tostring(item.claimed_epoch)) end
            end
            return fenced
        end
        test.it("lets a replacement take over rows the original claimed but never committed, and the original cannot acknowledge them", function()
            local fenced = two_carriers("hooks_claimed")
            local text = tostring(fenced.error)
            -- The thread refuses the original's commit: fenced by the newer
            -- epoch, or the attempt already ended under the replacement.
            if not (text:find("fenced", 1, true) or text:find("CONFLICT", 1, true) or text:find("epoch", 1, true) or text:find("DENIED", 1, true) or text:find("attempt has ended", 1, true)) then error("the original ended for another reason: " .. text) end
        end)
        test.it("lets a replacement replay rows the original committed but never acknowledged, leaving one observation", function()
            two_carriers("hooks_committed")
        end)
        test.it("lets a scripted agent author from the guide alone and repair a stray overlay on its remedy", function()
            -- The scripted child holds the plain request only: it learns the
            -- artifact from the overlay tool's guide operation over the real
            -- MCP surface. Round 1 authors only index.html and app.js and is
            -- refused with a named remedy; round 2 authors the guide's own
            -- example in the same overlay and the destination preflight is
            -- ready.
            install_policy("bee.harness.catalog:gateway_author_policy")
            local source = "counter"
            local environment = {BEE_FIXTURE_GATEWAY_AUTHOR = "repair", BEE_FIXTURE_AUTHOR_WORKSPACE = source,
                BEE_FIXTURE_AUTHOR_SOURCE = source, BEE_FIXTURE_AUTHOR_DESTINATION = AUTHOR_WORKSPACE,
                BEE_FIXTURE_AUTHOR_VERSION = "1.0.0", BEE_FIXTURE_STREAM = stream("plain.jsonl")}
            local thread_id = thread()
            local attempt_id = fresh("author")
            -- The gateway takes the delivery destination from the binding, so
            -- the authoring session is bound to the destination workspace.
            local authoring = request(thread_id, attempt_id, environment, nil, "bee.harness.catalog:gateway_author_policy")
            authoring.workspace_id = AUTHOR_WORKSPACE
            local outcome = run_carrier(authoring, "open", nil)
            if not outcome.value then error("authoring carrier failed: " .. tostring(outcome.error)) end
            test.eq((outcome.value.settlement :: Object).outcome, "succeeded")
            local seen = report(thread_id)
            test.eq(seen.author_has_guide, true)
            test.is_true(type(seen.guide_document) == "string" and (seen.guide_document :: string):find("entries.json", 1, true) ~= nil)
            test.eq(seen.guide_example_present, true)
            -- The stray round really held only the two files.
            local files = seen.author_files :: {Object}
            test.eq(#files, 2)
            -- Round 1 was refused with a named code and a remedy.
            test.eq(seen.refusal_ok, false)
            test.eq(seen.refusal_code, "MISSING_ARTIFACT")
            test.is_true(type(seen.refusal_remedy) == "string" and (seen.refusal_remedy :: string):find("entries.json", 1, true) ~= nil)
            -- Round 2 repaired exactly what the remedy named and delivery was ready.
            test.not_nil(seen.repaired_snapshot_digest)
            test.eq(seen.delivery_ready, true)
            local steps = seen.delivery_human_steps :: {string}
            test.eq(#steps, 6)
        end)
        test.it("releases a waiting child when the gateway drains", function()
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            -- The carrier holds before it records the attempt start, so the
            -- child reads the thread and waits on a cursor the start record
            -- then moves past: its first wait is ready, and the wait it
            -- starts from the new head is the one the drain releases.
            local pid = spawn_carrier(request(thread_id, attempt_id, {BEE_FIXTURE_GATEWAY_WAIT = "6000"}), "open", nil, "placement_started")
            await_presented(attempt_id, 1, 4)
            continue_carrier(pid)
            await_presented(attempt_id, 1, 5)
            call("bee.gateway.binding:drain", {deadline_ms = 8000})
            local outcome = await_carrier(pid, "draining carrier")
            open_gateway()
            if not outcome.value then error("carrier failed: " .. tostring(outcome.error)) end
            local seen = report(thread_id)
            if type(seen.wait) ~= "table" then error("no wait in report: " .. tostring(json.encode(seen))) end
            local waited = seen.wait :: Object
            if type(waited.outcome) ~= "table" then error("wait without outcome: " .. tostring(json.encode(seen))) end
            test.eq(waited.status, 200)
            local released = waited.outcome :: Object
            test.eq(released.status, "released")
            test.eq(released.reason, "draining")
            test.is_true((tonumber(waited.elapsed_ms) or 0) < 4000)
        end)
        test.it("refuses a token revoked while the child uses it", function()
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local pid = spawn_carrier(request(thread_id, attempt_id, {BEE_FIXTURE_GATEWAY_HOLD = "10"}), "open", nil, "attempt_started")
            await_presented(attempt_id, 1, 3)
            local live = binding_of(attempt_id, 1)
            test.eq(live.valid, true)
            call("bee.gateway.binding:revoke", {binding_id = live.binding_id})
            call("bee.placement.native.binding:reconcile", {attempt_id = attempt_id})
            continue_carrier(pid)
            local outcome = await_carrier(pid, "revoked carrier")
            if not outcome.value then error("carrier failed: " .. tostring(outcome.error)) end
            local seen = report(thread_id)
            test.eq(seen.read, 200)
            test.eq(seen.after_hold, 401)
        end)
    end)
end
return require("test").run_cases(define_tests)
