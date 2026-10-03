-- MIT. The carrier's permission exchange against the fixture harness: the
-- request becomes a checkpointed intent, the approval is asked under its
-- idempotency key, the decision is consumed under the current authority
-- and answered through one deterministic write, and every crash boundary
-- recovers without a second approval, a second response or an invented
-- resend. Fixture only: the shipped profiles stay none.
local test = require("test")
local principals = require("principals")
local bounds = require("bounds")
local placement_decode = require("placement_decode")
local placement_protocol = require("placement_protocol")
local funcs = require("funcs")
local security = require("security")
local process = require("process")
local registry = require("registry")
local env = require("env")
local time = require("time")
local channel = require("channel")
local json = require("json")
local exec = require("exec")
local hash = require("hash")
local catalog = require("catalog")
local adapter = require("adapter")
local approvals = require("approvals")
local placement_fixture = require("placement_fixture")
local exits = require("exits")
local ACTOR = "bee.test.carrier"
local APPROVER = "bee.test.approver"
local POLICY = "bee.harness.catalog:permission_fixture_policy"
local PRODUCTION_POLICY = "bee.harness.catalog:permission_production_policy"
local UNPINNED_POLICY = "bee.harness.catalog:permission_production_policy_unpinned"
local REAL_ADAPTER = "bee.driver.claude.permission:permission_adapter"
local PRODUCTION_ACCEPTANCE = "bee.harness.catalog:permission_production_acceptance"
local ADAPTER = "bee.harness.catalog:permission_fixture_adapter"
local ACCEPTANCE = "bee.harness.catalog:permission_fixture_acceptance"
local APPROVER_POLICY = "carrier-fixture"
local ROOT = "bee.harness.catalog:project_fixture"
local BINDING = "bee.driver.claude.binding:binding"
local REQUEST_ID = "perm-1"
local counter = 0
type Object = {[string]: unknown}
type Outcome = {value: Object?, error: string?}
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end
local carrier_scope = {"bee.harness.catalog:carrier_client_policy", "bee.security.threads:thread_create_policy", "bee.security.threads:thread_observe_policy", "bee.security.threads:thread_lifecycle_policy",
    "bee.security.threads:thread_carrier_policy", "bee.harness.security:carrier_policy", "bee.harness.catalog:carrier_spawn_policy", "bee.security.approvals:approval_request_policy", "bee.security.approvals:approval_consume_policy"}
local function scope(names: {string}): security.Scope
    local policies: {security.Policy} = {}
    for index, name in ipairs(names) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    return security.new_scope(policies)
end
local actor = security.new_actor(ACTOR)
local approver = funcs.new():with_actor(security.new_actor(APPROVER)):with_scope(scope({"bee.harness.catalog:approver_client_policy", "bee.security.approvals:approval_decide_policy"}))
local function reply_value(target: string, result: unknown, err: unknown): Object
    if err then error(target .. ": " .. tostring(err)) end
    local reply = result
    if not reply.ok then error(target .. ": " .. tostring(reply.error and reply.error.code) .. ": " .. tostring(reply.error and reply.error.message)) end
    return assert(bounds.object(reply.value))
end
local function call(target: string, request: unknown): Object
    local result, err = funcs.new():with_actor(actor):with_scope(scope(carrier_scope)):call(target, request)
    return reply_value(target, result, err)
end
local function approve_call(target: string, request: unknown): Object
    local result, err = approver:call(target, request)
    return reply_value(target, result, err)
end
local function fixture_paths(): (string, string)
    local bin, bin_error = env.get("bee.harness.catalog:fixture_bin")
    if bin_error or type(bin) ~= "string" or bin == "" then error("BEE_FIXTURE_BIN is not set for the test runtime") end
    local streams, streams_error = env.get("bee.harness.catalog:fixture_streams")
    if streams_error or type(streams) ~= "string" or streams == "" then error("BEE_FIXTURE_STREAMS is not set for the test runtime") end
    return bin .. "/claude", streams .. "/claude/stream-json-2/permission.jsonl"
end
local function shell(command: string): string
    local executor = assert(exec.get("bee.placement.native.env:placement_executor"))
    local proc = assert(executor:exec("sh -c '" .. command .. "'"))
    local stdout = proc:stdout_stream()
    assert(proc:start())
    local output = ""
    while true do
        local chunk: unknown = stdout:read(65536)
        if type(chunk) ~= "string" or chunk == "" then break end
        output = output .. (chunk)
    end
    proc:wait()
    stdout:close()
    executor:release()
    return output
end
local function file_digest(path: string): string
    local executor = assert(exec.get("bee.placement.native.env:placement_executor"))
    local proc = assert(executor:exec("cat " .. path))
    local stdout = proc:stdout_stream()
    assert(proc:start())
    local content = ""
    while true do
        local chunk: unknown = stdout:read(65536)
        if type(chunk) ~= "string" or chunk == "" then break end
        content = content .. (chunk)
    end
    proc:wait()
    stdout:close()
    executor:release()
    local digest, err = hash.sha256(content)
    if not digest then error("digest fixture: " .. tostring(err)) end
    return digest
end
local function apply(entry: Object)
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("apply " .. tostring(entry.id) .. ": " .. tostring(err)) end
end
local function fixture_adapter(): adapter.Adapter
    local entry = registry.get(ADAPTER)
    if not entry then error("fixture adapter entry") end
    local data = assert(bounds.object(entry.data))
    local decoded, err = adapter.decode(ADAPTER, data.adapter)
    if not decoded then error(tostring(err)) end
    return decoded
end
-- The host side of enabling the exchange: bind the executable, measure the
-- binding and profile, record acceptance for this fixture digest, and name
-- the adapter, the acceptance record and the approver policy in the policy.
-- The executable measurement placement takes, or the zero digest where
-- this runtime cannot measure the file; a fixture policy proceeds without
-- a measurement, a production one does not.
type Measured = {revision: string, kind: string, digest: string}
local function measure_executable(path: string): Measured
    local raw, err = funcs.new():with_actor(actor):with_scope(scope(carrier_scope)):call("bee.placement.native.binding:measure_executable", {path = path})
    if err then error("measure executable: " .. tostring(err)) end
    local reply = raw
    if reply.ok and reply.value then
        local measured = assert(bounds.object(reply.value))
        return {revision = tostring(measured.revision), kind = tostring(measured.kind), digest = tostring(measured.digest)}
    end
    return {revision = "bee.executable-measurement@1", kind = "other", digest = string.rep("0", 64)}
end
local function executable_digest(path: string): string
    return measure_executable(path).digest
end
local function prepare_host(): string
    local executable, stream = fixture_paths()
    local fixture_digest = file_digest(stream)
    local pinned = fixture_adapter()
    local snapshot = assert(catalog.snapshot())
    local usable = assert(catalog.usable(snapshot))
    local binding_digest, profile_digest = "", ""
    for _, candidate in ipairs(usable) do
        if candidate.binding_id == BINDING then binding_digest, profile_digest = candidate.binding_digest.entry, candidate.profile_digest.entry end
    end
    if binding_digest == "" then error("the Claude binding is not usable on this host") end
    local record = registry.get(ACCEPTANCE)
    if not record then error("acceptance entry") end
    (assert(bounds.object(record.data))).acceptance = {schema_revision = "bee.permission-acceptance@2", binding_id = BINDING, profile_id = "batch", binding_digest = binding_digest, profile_digest = profile_digest,
        adapter_ref = ADAPTER, adapter_digest = pinned.digest, fixture_digest = fixture_digest, executable_revision = measure_executable(executable).revision, executable_kind = measure_executable(executable).kind, executable_digest = measure_executable(executable).digest, proof_revision = "bee.permission-proof@1", accepted_by = "bee.test.operator", accepted_at = "2026-09-09T00:00:00.000Z"}
    apply(record)
    local policy = registry.get(POLICY)
    if not policy then error("permission policy entry") end
    local data = assert(bounds.object(policy.data))
    data.executables = {claude = executable}
    data.permission_exchange = {adapter_ref = ADAPTER, acceptance_ref = ACCEPTANCE, fixture_digest = fixture_digest, approver_policy = APPROVER_POLICY, poll_ms = 2000, ttl_ms = 60000}
    apply(policy)
    -- Production-shaped policies: one naming the real adapter the profile
    -- pins, with an acceptance record this suite fills, and one naming the
    -- fixture adapter no profile pins.
    local real_entry = registry.get(REAL_ADAPTER)
    if not real_entry then error("real adapter entry") end
    local real_adapter, real_error = adapter.decode(REAL_ADAPTER, (assert(bounds.object(real_entry.data))).adapter)
    if not real_adapter then error(tostring(real_error)) end
    local streams, streams_error = env.get("bee.harness.catalog:fixture_streams")
    if streams_error or type(streams) ~= "string" then error("BEE_FIXTURE_STREAMS is not set for the test runtime") end
    local capture_digest = file_digest(streams .. "/claude/stream-json-2/control.jsonl")
    local production_record = registry.get(PRODUCTION_ACCEPTANCE)
    if not production_record then error("production acceptance entry") end
    local measured_fixture = measure_executable(executable)
    local production_acceptance = assert(bounds.object(production_record.data))
    production_acceptance.acceptance = {schema_revision = "bee.permission-acceptance@2", binding_id = BINDING, profile_id = "batch", binding_digest = binding_digest, profile_digest = profile_digest,
        adapter_ref = REAL_ADAPTER, adapter_digest = real_adapter.digest, fixture_digest = capture_digest, executable_revision = measured_fixture.revision, executable_kind = measured_fixture.kind,
        executable_digest = measured_fixture.digest, proof_revision = "bee.permission-proof@1", accepted_by = "bee.test.operator", accepted_at = "2026-09-09T00:00:00.000Z"}
    apply(production_record)
    local production = registry.get(PRODUCTION_POLICY)
    if not production then error("production policy entry") end
    local production_data = assert(bounds.object(production.data))
    production_data.executables = {claude = executable}
    production_data.permission_exchange = {adapter_ref = REAL_ADAPTER, acceptance_ref = PRODUCTION_ACCEPTANCE, fixture_digest = capture_digest, approver_policy = APPROVER_POLICY, poll_ms = 2000, ttl_ms = 60000}
    apply(production)
    local unpinned = registry.get(UNPINNED_POLICY)
    if not unpinned then error("unpinned policy entry") end
    local unpinned_data = assert(bounds.object(unpinned.data))
    unpinned_data.executables = {claude = executable}
    unpinned_data.permission_exchange = {adapter_ref = ADAPTER, acceptance_ref = ACCEPTANCE, fixture_digest = fixture_digest, approver_policy = APPROVER_POLICY, poll_ms = 2000, ttl_ms = 60000}
    apply(unpinned)
    local mode = registry.get("bee.placement.native.env:placement_resource_mode")
    if not mode then error("placement resource mode entry") end
    mode.data = {mode = "host_configured"}
    apply(mode)
    local policies_entry = registry.get("bee.security.approvals:approver_policies")
    if not policies_entry then error("approver policies entry") end
    local list_owner = assert(bounds.object(policies_entry.data))
    local list = principals.objects(list_owner.policies)
    list_owner.policies = list
    local present = false
    for _, item in ipairs(list) do
        if item.name == APPROVER_POLICY then present = true end
    end
    if not present then
        list[#list + 1] = {name = APPROVER_POLICY, approvers = {APPROVER}, max_ttl_ms = 60000}
        apply(policies_entry)
    end
    local roots = registry.get("bee.placement.native.env:placement_admitted_roots")
    if not roots then error("admitted roots entry") end
    local root_list_owner = assert(bounds.object(roots.data))
    local root_list = principals.objects(root_list_owner.roots)
    root_list_owner.roots = root_list
    local admitted = false
    for _, root in ipairs(root_list) do
        if root.root_ref == ROOT then admitted = true end
    end
    if not admitted then
        root_list[#root_list + 1] = {root_ref = ROOT, access = "write"}
        apply(roots)
    end
    return stream
end
local function thread(): string
    local created = call("bee.threads.binding:create", {thread_id = fresh("thread"), idempotency_key = fresh("key"), title = "Permission carrier"})
    if type(created.thread_id) ~= "string" then error("invalid fixture created.thread_id") end
    return created.thread_id
end
local function request(thread_id: string, attempt_id: string, workspace: string, stream: string, timeout: string?): Object
    local placement = placement_fixture.resolve()
    local environment: {[string]: string} = {BEE_FIXTURE_STREAM = stream, BEE_FIXTURE_PERMISSION = REQUEST_ID}
    if timeout then environment.BEE_FIXTURE_PERMISSION_TIMEOUT = timeout end
    return {thread_id = thread_id, action_id = "action-" .. attempt_id, attempt_id = attempt_id, owner_id = ACTOR, owner_incarnation = 1, binding_ref = BINDING,
        profile_id = "batch", brief = "read the notes", policy_ref = POLICY, resources = {{name = "project", grant_ref = "host", root_ref = ROOT, subpath = "", access = "write", purpose = "project"}},
        environment = environment, working_directory = "project", workspace_id = workspace,
        placement_binding_ref = placement.binding_id, placement_binding_digest = placement.binding_digest}
end
local function spawn_carrier(entry: string, request_value: Object, mode: string, crash_after: string?, pause_after: string?): string
    local spawner = process.with_context({["bee.test.carrier.progress"] = true}):with_actor(actor):with_scope(scope(carrier_scope))
    local pid, err = spawner:spawn_monitored(entry, "bee:workers", request_value, mode, process.pid(), crash_after, nil, pause_after)
    if not pid then error("spawn carrier: " .. tostring(err)) end
    return tostring(pid)
end
-- Waits for the carrier's report that it holds at the named step, instead
-- of a fixed sleep guessing how long the carrier takes to reach it under a
-- busy host. The caller listens for bee.carrier.paused before spawning.
local exited: {[string]: Outcome} = {}
local function await_paused(paused: Channel<process.Message>, pid: string, wanted: string)
    local events = assert(process.events())
    exits.paused(pid, wanted, exited, function(poll: boolean): unknown
        local selected
        if poll then
            selected = channel.select({paused:case_receive(), default = true})
            if selected.default then return nil end
        else
            selected = channel.select({paused:case_receive(), events:case_receive()})
        end
        assert(selected.ok, "barrier observation channel closed")
        if selected.channel == events then return selected.value end
        local message = selected.value
        return {kind = "pause", from = tostring(message:from()), step = message:payload():data()}
    end)
end
local function await_carriers(pids: {string}, label: string?): {[string]: Outcome}
    local events = assert(process.events())
    local function all_done(): boolean
        for _, pid in ipairs(pids) do
            if not exited[pid] then return false end
        end
        return true
    end
    while not all_done() do
        local selected = channel.select({events:case_receive()})
        assert(selected.ok, (label or "carrier") .. " supervision channel closed")
        local event = selected.value
        if event.kind == process.event.EXIT then
            local result = event.result or {}
            local value: Object? = nil
            if type(result.value) == "table" then value = assert(bounds.object(result.value)) end
            exited[tostring(event.from)] = {value = value, error = result.error and tostring(result.error) or nil}
        end
    end
    local outcomes: {[string]: Outcome} = {}
    for _, pid in ipairs(pids) do outcomes[pid] = exited[pid] end
    return outcomes
end
local function await_carrier(pid: string, label: string?): Outcome
    return assert(await_carriers({pid}, label)[pid])
end
-- The approver's side: catch up on the workspace inbox until the request
-- is pending, then decide it for the recorded proposal digest.
local progress: Channel<process.Message>? = nil
local function await_request(workspace: string, pid: string): Object
    await_paused(assert(progress), pid, "approval_created")
    local page = approve_call("bee.approvals.binding:inbox", {workspace_id = workspace})
    for _, change in ipairs(principals.objects(page.changes)) do
        local view = assert(bounds.object(change.request))
        if view.state == "pending" then return view end
    end
    error("approval_created acknowledged without a pending request in workspace " .. workspace)
end
local function pending_request(workspace: string): Object
    local page = approve_call("bee.approvals.binding:inbox", {workspace_id = workspace})
    for _, change in ipairs(principals.objects(page.changes)) do
        local view = assert(bounds.object(change.request))
        if view.state == "pending" then return view end
    end
    error("no pending approval request in workspace " .. workspace)
end
local function decide(view: Object, decision: string)
    approve_call("bee.approvals.binding:decide", {approval_id = view.approval_id, expected_revision = view.revision, decision = decision, proposal_digest = view.proposal_digest})
end
local function records_of(thread_id: string): {Object}
    local all: {Object} = {}
    local cursor = 0
    for _ = 1, 32 do
        local page = call("bee.threads.binding:read_after", {thread_id = thread_id, cursor = cursor, limit = 64})
        for _, item in ipairs(principals.objects(page.records)) do all[#all + 1] = item end
        if page.has_more ~= true then break end
        if type(page.scanned_through) ~= "number" then error("invalid fixture page.scanned_through") end
        cursor = math.floor(page.scanned_through)
    end
    return all
end
local function payloads(records: {Object}, event_name: string): {Object}
    local found: {Object} = {}
    for _, item in ipairs(records) do
        local body = assert(bounds.object(item.body))
        if body.type == "extension" then
            local data = assert(bounds.object(body.data))
            if data.event_name == event_name then found[#found + 1] = assert(bounds.object(json.decode(tostring(data.payload_json)))) end
        end
    end
    return found
end
local function phases(records: {Object}): {string}
    local list: {string} = {}
    for _, payload in ipairs(payloads(records, "bee.carrier.permission")) do list[#list + 1] = tostring(payload.phase) end
    return list
end
local function writes(records: {Object}): {string}
    local list: {string} = {}
    for _, payload in ipairs(payloads(records, "bee.carrier.write")) do list[#list + 1] = tostring(payload.phase) end
    return list
end
local function count(list: {string}, wanted: string): integer
    local total = 0
    for _, item in ipairs(list) do
        if item == wanted then total = total + 1 end
    end
    return total
end
local function tool_results(records: {Object}): integer
    local total = 0
    for _, item in ipairs(records) do
        local body = assert(bounds.object(item.body))
        if body.type == "tool.result" then
            local data = assert(bounds.object(body.data))
            if data.call_id == REQUEST_ID then total = total + 1 end
        end
    end
    return total
end
local function stderr_mentions(records: {Object}, marker: string): integer
    local total = 0
    for _, item in ipairs(records) do
        local body = assert(bounds.object(item.body))
        if body.type == "notice" then
            local data = assert(bounds.object(body.data))
            local content = bounds_text(data.content)
            if data.code == "stderr" and content:find(marker, 1, true) then total = total + 1 end
        end
    end
    return total
end
function bounds_text(value: unknown): string
    if type(value) ~= "table" then return "" end
    return tostring((assert(bounds.object(value))).text or "")
end
local function hint(pid: string, thread_id: string)
    process.send(pid, "bee.carrier.hints." .. pid, {woke = true, thread_id = thread_id})
end
local function settlement_of(outcome: Outcome, label: string): Object
    if not outcome.value then error(label .. ": " .. tostring(outcome.error)) end
    return assert(bounds.object(outcome.value.settlement))
end
local function approvals_in(workspace: string): integer
    local listed = call("bee.approvals.binding:list", {workspace_id = workspace})
    return #(principals.items(listed.requests))
end
local function define_tests()
    test.describe("Carrier permission exchange", function()
        progress = assert(process.listen("bee.test.carrier.progress", {message = true}))
        local stream = prepare_host()
        test.it("asks, waits, consumes and answers an allowed request through one deterministic write, woken by a hint rather than the poll", function()
            -- The approval hint wakes this exchange before its next periodic poll.
            local policy = assert(registry.get(POLICY))
            local exchange = (assert(bounds.object((assert(bounds.object(policy.data))).permission_exchange)))
            exchange.poll_ms = 120000
            apply(policy)
            local thread_id, workspace, attempt_id = thread(), fresh("ws"), fresh("attempt")
            local pid = spawn_carrier("bee.harness.service:carrier", request(thread_id, attempt_id, workspace, stream, nil), "open", nil)
            local view = await_request(workspace, pid)
            test.eq(view.request_kind, "permission")
            test.eq((assert(bounds.object(view.proposal))).kind, "attempt")
            for _ = 1, 3 do hint(pid, thread_id) end
            decide(view, "approved")
            for _ = 1, 3 do hint(pid, thread_id) end
            local finished, outcome = pcall(function(): Outcome return await_carrier(pid) end)
            exchange.poll_ms = 2000
            apply(policy)
            if not finished then error(tostring(outcome)) end
            local settlement = settlement_of(outcome, "allow run")
            test.eq(settlement.outcome, "succeeded")
            test.eq(settlement.answer, "The file says: hello from notes")
            local records = records_of(thread_id)
            local list = phases(records)
            for _, phase in ipairs({"intended", "requested", "decided", "consumed", "acknowledged"}) do test.eq(count(list, phase), 1) end
            test.eq(count(list, "revalidated"), 0)
            test.eq(table.concat(writes(records), ","), "intended,accepted")
            test.eq(tool_results(records), 1)
            test.eq(stderr_mentions(records, "malformed"), 0)
            local consumed = approve_call("bee.approvals.binding:read", {approval_id = view.approval_id})
            test.eq(consumed.consumer_id, ACTOR)
            test.eq(approvals_in(workspace), 1)
            -- The session ended the declared way: stdin closed at the
            -- owner's request and recorded, or the cooperative stop where
            -- the runtime cannot close stdin; either is on record apart
            -- from input acceptance and exit.
            local evidence: {string} = {}
            for _, item in ipairs(principals.objects(call("bee.placement.native.binding:evidence", {attempt_id = attempt_id, limit = 64}).evidence)) do evidence[#evidence + 1] = tostring(item.kind) end
            local input_phases: {string} = {}
            for _, payload in ipairs(payloads(records_of(thread_id), "bee.carrier.input")) do input_phases[#input_phases + 1] = tostring(payload.phase) end
            if count(evidence, "stdin.closed") == 1 then
                test.eq(table.concat(input_phases, ","), "close_intended,closed")
            else
                test.eq(count(evidence, "stdin.uncertain"), 1)
                test.eq(count(evidence, "stop.requested"), 1)
                test.eq(table.concat(input_phases, ","), "close_intended,close_uncertain")
            end
            test.eq(count(evidence, "child.exited"), 1)
        end)
        test.it("refuses a production exchange on this host with the requirement it lacks, before any launch", function()
            local thread_id, workspace = thread(), fresh("ws")
            local launch = request(thread_id, fresh("attempt"), workspace, stream, nil)
            launch.policy_ref = UNPINNED_POLICY
            local unpinned = await_carrier(spawn_carrier("bee.harness.service:carrier", launch, "open", nil), "unpinned policy")
            test.is_nil(unpinned.value)
            if not tostring(unpinned.error):find("does not pin permission adapter", 1, true) then error("unpinned policy ended with: " .. tostring(unpinned.error)) end
            local pinned_thread, pinned_workspace = thread(), fresh("ws")
            local pinned_launch = request(pinned_thread, fresh("attempt"), pinned_workspace, stream, nil)
            pinned_launch.policy_ref = PRODUCTION_POLICY
            local outcome = await_carrier(spawn_carrier("bee.harness.service:carrier", pinned_launch, "open", nil), "production policy")
            test.is_nil(outcome.value)
            if not tostring(outcome.error):find("production exchange:", 1, true) then error("production policy ended with: " .. tostring(outcome.error)) end
            test.eq(#records_of(thread_id), 0)
            test.eq(#records_of(pinned_thread), 0)
        end)
        test.it("answers a denied request and records the terminal denial as its acknowledgment", function()
            local thread_id, workspace = thread(), fresh("ws")
            local pid = spawn_carrier("bee.harness.service:carrier", request(thread_id, fresh("attempt"), workspace, stream, nil), "open", nil)
            decide(await_request(workspace, pid), "denied")
            local settlement = settlement_of(await_carrier(pid), "deny run")
            test.eq(settlement.outcome, "failed")
            local records = records_of(thread_id)
            local list = phases(records)
            test.eq(count(list, "consumed"), 0)
            test.eq(count(list, "declined"), 1)
            test.eq(count(list, "acknowledged"), 1)
            test.eq(table.concat(writes(records), ","), "intended,accepted")
            test.eq(tool_results(records), 0)
        end)
        test.it("recovers every boundary before the response with one approval and one response", function()
            for _, crash in ipairs({"permission_intended", "approval_created", "permission_requested", "permission_consumed", "write_intended", "write_dispatched"}) do
                local thread_id, workspace = thread(), fresh("ws")
                local launch = request(thread_id, fresh("attempt"), workspace, stream, nil)
                local paused = assert(process.listen("bee.carrier.paused", {message = true}))
                local decided_before = crash == "permission_consumed" or crash == "write_intended" or crash == "write_dispatched"
                local first = spawn_carrier("bee.harness.catalog:carrier_faulted", launch, "open", crash, decided_before and "approval_created" or nil)
                if decided_before then
                    await_paused(paused, first, "approval_created")
                    decide(pending_request(workspace), "approved")
                    process.send(first, "bee.carrier.continue", {go = true})
                end
                local crashed = await_carrier(first, crash)
                test.is_true(tostring(crashed.error):find("crash after " .. crash, 1, true) ~= nil)
                if not decided_before and crash ~= "permission_intended" then
                    decide(pending_request(workspace), "approved")
                end
                local resumed = spawn_carrier("bee.harness.catalog:carrier_faulted", launch, "resume", nil,
                    crash == "permission_intended" and "checkpoint_read,approval_created" or nil)
                if crash == "permission_intended" then
                    await_paused(paused, resumed, "checkpoint_read")
                    test.eq(approvals_in(workspace), 0)
                    process.send(resumed, "bee.carrier.continue", {go = true})
                    await_paused(paused, resumed, "approval_created")
                    decide(pending_request(workspace), "approved")
                    process.send(resumed, "bee.carrier.continue", {go = true})
                end
                process.unlisten(paused)
                local settlement = settlement_of(await_carrier(resumed, crash .. " resume"), crash)
                local records = records_of(thread_id)
                if settlement.outcome ~= "succeeded" then
                    error(crash .. ": settled " .. tostring(settlement.outcome) .. " (" .. tostring(settlement.reason) .. "); phases " .. table.concat(phases(records), ",") .. "; writes " .. table.concat(writes(records), ",") .. "; uncorrelated " .. tostring(stderr_mentions(records, "uncorrelated")) .. "; malformed " .. tostring(stderr_mentions(records, "malformed")))
                end
                test.eq(approvals_in(workspace), 1)
                local approval_records = 0
                for _, item in ipairs(records) do
                    if item.kind == "approval.request" then approval_records = approval_records + 1 end
                end
                test.eq(approval_records, 1)
                test.eq(count(phases(records), "consumed"), 1)
                test.eq(table.concat(writes(records), ","), "intended,accepted")
                test.eq(tool_results(records), 1)
                test.eq(stderr_mentions(records, "malformed"), 0)
                test.eq(stderr_mentions(records, "uncorrelated"), 0)
            end
        end)
        test.it("revalidates again when the authority restarts between revalidation and consumption", function()
            local thread_id, workspace = thread(), fresh("ws")
            local launch = request(thread_id, fresh("attempt"), workspace, stream, nil)
            local paused = assert(process.listen("bee.carrier.paused", {message = true}))
            local pid = spawn_carrier("bee.harness.catalog:carrier_faulted", launch, "open", nil, "permission_revalidated")
            local view = await_request(workspace, pid)
            local db = assert(approvals.open())
            assert(approvals.establish(db))
            decide(view, "approved")
            await_paused(paused, pid, "permission_revalidated")
            process.unlisten(paused)
            assert(approvals.establish(db))
            db:release()
            process.send(pid, "bee.carrier.continue", {go = true})
            local settlement = settlement_of(await_carrier(pid, "revalidation run"), "revalidation")
            test.eq(settlement.outcome, "succeeded")
            local records = records_of(thread_id)
            local list = phases(records)
            test.eq(count(list, "revalidated"), 2)
            test.eq(count(list, "consumed"), 1)
            test.eq(tool_results(records), 1)
        end)
        test.it("keeps deciding through polling when the hint subscription is lost", function()
            local thread_id, workspace = thread(), fresh("ws")
            local launch = request(thread_id, fresh("attempt"), workspace, stream, nil)
            local paused = assert(process.listen("bee.carrier.paused", {message = true}))
            local pid = spawn_carrier("bee.harness.catalog:carrier_faulted", launch, "open", nil, "hints_opened")
            await_paused(paused, pid, "hints_opened")
            process.unlisten(paused)
            local stored = call("bee.threads.binding:checkpoint", {thread_id = thread_id, attempt_id = launch.attempt_id})
            local point = assert(bounds.object(stored.checkpoint))
            local subscription_id = tostring(point.hint_subscription)
            test.is_true(#subscription_id > 0)
            call("bee.threads.binding:unsubscribe", {thread_id = thread_id, idempotency_key = fresh("key"), subscription_id = subscription_id})
            process.send(pid, "bee.carrier.continue", {go = true})
            local view = await_request(workspace, pid)
            decide(view, "approved")
            local settlement = settlement_of(await_carrier(pid, "lost subscription"), "lost subscription")
            test.eq(settlement.outcome, "succeeded")
            local records = records_of(thread_id)
            test.eq(count(phases(records), "consumed"), 1)
            test.eq(tool_results(records), 1)
        end)
        test.it("refuses to dispatch after recovery when the launch policy no longer measures as planned", function()
            local thread_id, workspace = thread(), fresh("ws")
            local launch = request(thread_id, fresh("attempt"), workspace, stream, nil)
            local first = spawn_carrier("bee.harness.catalog:carrier_faulted", launch, "open", "permission_consumed")
            decide(await_request(workspace, first), "approved")
            local crashed = await_carrier(first, "permission_consumed")
            test.is_true(tostring(crashed.error):find("crash after permission_consumed", 1, true) ~= nil)
            local policy = registry.get(POLICY)
            if not policy then error("permission policy entry") end
            local data = assert(bounds.object(policy.data))
            local drain = data.drain_ms
            data.drain_ms = 2500
            apply(policy)
            local resumed = spawn_carrier("bee.harness.catalog:carrier_faulted", launch, "resume", nil)
            local settlement = settlement_of(await_carrier(resumed, "changed policy"), "changed policy")
            data.drain_ms = drain
            apply(policy)
            test.neq(settlement.outcome, "succeeded")
            local records = records_of(thread_id)
            test.eq(#writes(records), 0)
            test.eq(tool_results(records), 0)
            local closed = false
            for _, payload in ipairs(payloads(records, "bee.carrier.permission")) do
                if payload.phase == "closed" and tostring(payload.reason):find("plan measurements changed", 1, true) then closed = true end
            end
            test.is_true(closed)
        end)
        -- A copy of the fixture executable bound in the policy, so its
        -- measurement can change under a decided exchange.
        local function bind_copy(): (string, string)
            local original = fixture_paths()
            local copy = ".wippy/measured-claude-" .. fresh("copy")
            shell("cp " .. original .. " " .. copy .. " && chmod +x " .. copy)
            local policy = registry.get(POLICY)
            if not policy then error("permission policy entry") end
            local data = assert(bounds.object(policy.data))
            data.executables = {claude = shell("pwd"):gsub("%s+$", "") .. "/" .. copy}
            apply(policy)
            return copy, original
        end
        local function unbind_copy(original: string, copy: string)
            local policy = registry.get(POLICY)
            if not policy then error("permission policy entry") end
            local data = assert(bounds.object(policy.data))
            data.executables = {claude = original}
            apply(policy)
            shell("rm -f " .. copy)
        end
        test.it("refuses to dispatch after recovery when the executable no longer measures as accepted, keeping the decision", function()
            local copy, original = bind_copy()
            local thread_id, workspace = thread(), fresh("ws")
            local launch = request(thread_id, fresh("attempt"), workspace, stream, nil)
            local first = spawn_carrier("bee.harness.catalog:carrier_faulted", launch, "open", "permission_consumed")
            local view = await_request(workspace, first)
            decide(view, "approved")
            local crashed = await_carrier(first, "permission_consumed")
            test.is_true(tostring(crashed.error):find("crash after permission_consumed", 1, true) ~= nil)
            shell('printf "# changed after the decision\\n" >> ' .. copy)
            local settlement = settlement_of(await_carrier(spawn_carrier("bee.harness.catalog:carrier_faulted", launch, "resume", nil), "changed executable"), "changed executable")
            unbind_copy(original, copy)
            if settlement.outcome == "succeeded" then error("dispatched after the executable changed: phases " .. table.concat(phases(records_of(thread_id)), ",")) end
            local records = records_of(thread_id)
            test.eq(#writes(records), 0)
            test.eq(tool_results(records), 0)
            local closed = ""
            for _, payload in ipairs(payloads(records, "bee.carrier.permission")) do
                if payload.phase == "closed" then closed = tostring(payload.reason) end
            end
            test.is_true(closed:find("executable measurement changed since acceptance", 1, true) ~= nil)
            local record = approve_call("bee.approvals.binding:read", {approval_id = view.approval_id})
            test.eq(record.decision, "approved")
            test.eq(record.decider_id, APPROVER)
        end)
        test.it("refuses to dispatch when the plan changed between revalidation and consumption under a restarted authority", function()
            local copy, original = bind_copy()
            local thread_id, workspace = thread(), fresh("ws")
            local launch = request(thread_id, fresh("attempt"), workspace, stream, nil)
            local paused = assert(process.listen("bee.carrier.paused", {message = true}))
            local pid = spawn_carrier("bee.harness.catalog:carrier_faulted", launch, "open", nil, "permission_revalidated")
            local view = await_request(workspace, pid)
            local db = assert(approvals.open())
            assert(approvals.establish(db))
            decide(view, "approved")
            await_paused(paused, pid, "permission_revalidated")
            process.unlisten(paused)
            shell('printf "# changed between revalidation and consumption\\n" >> ' .. copy)
            assert(approvals.establish(db))
            db:release()
            process.send(pid, "bee.carrier.continue", {go = true})
            local settlement = settlement_of(await_carrier(pid, "changed between validation and consumption"), "changed plan")
            unbind_copy(original, copy)
            test.neq(settlement.outcome, "succeeded")
            local records = records_of(thread_id)
            test.eq(#writes(records), 0)
            test.eq(tool_results(records), 0)
            local closed = ""
            for _, payload in ipairs(payloads(records, "bee.carrier.permission")) do
                if payload.phase == "closed" then closed = tostring(payload.reason) end
            end
            test.is_true(closed:find("executable measurement changed since acceptance", 1, true) ~= nil)
            local record = approve_call("bee.approvals.binding:read", {approval_id = view.approval_id})
            test.eq(record.decision, "approved")
        end)
        test.it("leaves a write uncertain when the runner is lost during recovery and sends nothing after settlement", function()
            local thread_id, workspace = thread(), fresh("ws")
            local launch = request(thread_id, fresh("attempt"), workspace, stream, nil)
            local first = spawn_carrier("bee.harness.catalog:carrier_faulted", launch, "open", "write_intended")
            decide(await_request(workspace, first), "approved")
            local crashed = await_carrier(first, "write_intended")
            test.is_true(tostring(crashed.error):find("crash after write_intended", 1, true) ~= nil)
            local status = assert(placement_decode.status(call("bee.placement.native.binding:status", {attempt_id = launch.attempt_id})))
            local runner = assert(status.attempt.runner)
            assert(process.monitor(runner))
            local exits = assert(process.listen(placement_protocol.TOPIC_EXIT, {message = true}))
            local generation = status.attempt.attachment_generation + 1
            call("bee.placement.native.binding:attach", {attempt_id = launch.attempt_id, recipient = process.pid(), generation = generation})
            call("bee.placement.native.binding:stop", {attempt_id = launch.attempt_id, mode = "forced"})
            local selected = channel.select({exits:case_receive()})
            assert(selected.ok and selected.channel == exits, "placement child did not exit")
            local message = selected.value
            test.eq(tostring(message:from()), runner)
            local child_exit = assert(placement_protocol.decode_exit(message:payload():data()))
            test.eq(child_exit.attempt_id, launch.attempt_id)
            test.eq(child_exit.generation, generation)
            process.unlisten(exits)
            assert(process.terminate(runner))
            await_carrier(runner, "placement runner loss")
            process.unmonitor(runner)
            local reconciled = call("bee.placement.native.binding:reconcile", {attempt_id = launch.attempt_id})
            test.eq(reconciled.execution_state, "exited")
            local settlement = settlement_of(await_carrier(spawn_carrier("bee.harness.catalog:carrier_faulted", launch, "resume", nil), "lost runner"), "lost runner")
            test.neq(settlement.outcome, "succeeded")
            local records = records_of(thread_id)
            test.eq(table.concat(writes(records), ","), "intended,uncertain")
            test.eq(tool_results(records), 0)
            local late_thread, late_workspace = thread(), fresh("ws")
            -- Observe the abandoned child's actual exit before approving;
            -- the fixture declares a one-second permission protocol bound.
            local late_launch = request(late_thread, fresh("attempt"), late_workspace, stream, "1")
            local paused = spawn_carrier("bee.harness.catalog:carrier_faulted", late_launch, "open", "permission_requested")
            local late_view = await_request(late_workspace, paused)
            await_carrier(paused, "permission_requested")
            local late_exits = assert(process.listen(placement_protocol.TOPIC_EXIT, {message = true}))
            local late_status = assert(placement_decode.status(call("bee.placement.native.binding:status", {attempt_id = late_launch.attempt_id})))
            local late_runner = assert(late_status.attempt.runner)
            local late_generation = late_status.attempt.attachment_generation + 1
            call("bee.placement.native.binding:attach", {attempt_id = late_launch.attempt_id, recipient = process.pid(), generation = late_generation})
            while true do
                local message = assert((late_exits:receive()))
                local observed = assert(placement_protocol.decode_exit(message:payload():data()))
                if tostring(message:from()) == late_runner and observed.attempt_id == late_launch.attempt_id and observed.generation == late_generation then break end
            end
            process.unlisten(late_exits)
            decide(late_view, "approved")
            local late = settlement_of(await_carrier(spawn_carrier("bee.harness.catalog:carrier_faulted", late_launch, "resume", nil), "late decision"), "late decision")
            test.neq(late.outcome, "succeeded")
            local late_records = records_of(late_thread)
            test.eq(#writes(late_records), 0)
            test.eq(count(phases(late_records), "closed"), 1)
            test.eq(tool_results(late_records), 0)
            local projected = 0
            while projected == 0 do
                local after = 0
                for _, item in ipairs(records_of(late_thread)) do
                    after = assert(bounds.integer(item.sequence))
                    if item.kind == "approval.transition" then projected = projected + 1 end
                end
                if projected == 0 then
                    local changed = call("bee.threads.binding:watch", {thread_id = late_thread, after_sequence = after, wait_ms = 60000})
                    assert(changed.status == "ready", "approval projection exceeded the requested 60000 ms thread watch")
                end
            end
            test.eq(projected, 1)
        end)
    end)
end
local cases = test.run_cases(define_tests)
-- prepare_host changes shared host entries; later suites in the same
-- runtime see the originals.
return {run = function(options)
    local before = assert(registry.snapshot())
    local ok, result = pcall(cases, options)
    local changes = assert(registry.snapshot()):changes()
    for _, ref in ipairs({ACCEPTANCE, POLICY, PRODUCTION_ACCEPTANCE, PRODUCTION_POLICY, UNPINNED_POLICY,
        "bee.placement.native.env:placement_resource_mode", "bee.security.approvals:approver_policies", "bee.placement.native.env:placement_admitted_roots"}) do
        changes:update(assert(before:get(ref)))
    end
    assert(changes:apply())
    if not ok then error(tostring(result)) end
    return result
end}
