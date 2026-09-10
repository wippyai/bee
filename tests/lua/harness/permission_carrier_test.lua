-- MIT. The carrier's permission exchange against the fixture harness: the
-- request becomes a checkpointed intent, the approval is asked under its
-- idempotency key, the decision is consumed under the current authority
-- and answered through one deterministic write, and every crash boundary
-- recovers without a second approval, a second response or an invented
-- resend. Fixture only: the shipped profiles stay none.
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
local hash = require("hash")
local catalog = require("catalog")
local adapter = require("adapter")
local approvals = require("approvals")
local ACTOR = "bee.test.carrier"
local APPROVER = "bee.test.approver"
local POLICY = "bee.harness.catalog:permission_fixture_policy"
local PRODUCTION_POLICY = "bee.harness.catalog:permission_production_policy"
local UNPINNED_POLICY = "bee.harness.catalog:permission_production_policy_unpinned"
local REAL_ADAPTER = "bee.driver.claude:permission_adapter"
local PRODUCTION_ACCEPTANCE = "bee.harness.catalog:permission_production_acceptance"
local ADAPTER = "bee.harness.catalog:permission_fixture_adapter"
local ACCEPTANCE = "bee.harness.catalog:permission_fixture_acceptance"
local APPROVER_POLICY = "carrier-fixture"
local ROOT = "bee.harness.catalog:project_fixture"
local BINDING = "bee.driver.claude:binding"
local REQUEST_ID = "perm-1"
local counter = 0
type Object = {[string]: unknown}
type Outcome = {value: Object?, error: string?}
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end
local carrier_scope = {"bee.harness.catalog:carrier_client_policy", "bee:thread_create_policy", "bee:thread_observe_policy", "bee:thread_lifecycle_policy",
    "bee:thread_carrier_policy", "bee:carrier_policy", "bee.harness.catalog:carrier_spawn_policy", "bee:approval_request_policy", "bee:approval_consume_policy"}
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
local approver = funcs.new():with_actor(security.new_actor(APPROVER)):with_scope(scope({"bee.harness.catalog:approver_client_policy", "bee:approval_decide_policy"}))
local function reply_value(target: string, result: unknown, err: unknown): Object
    if err then error(target .. ": " .. tostring(err)) end
    local reply = result :: {ok: boolean, error: {code: string, message: string}?, value: unknown}
    if not reply.ok then error(target .. ": " .. tostring(reply.error and reply.error.code) .. ": " .. tostring(reply.error and reply.error.message)) end
    return reply.value :: Object
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
    local executor = assert(exec.get("bee.placement.native:executor"))
    local proc = assert(executor:exec("sh -c '" .. command .. "'"))
    local stdout = proc:stdout_stream()
    assert(proc:start())
    local output = ""
    while true do
        local chunk: unknown = stdout:read(65536)
        if type(chunk) ~= "string" or chunk == "" then break end
        output = output .. (chunk :: string)
    end
    proc:wait()
    stdout:close()
    executor:release()
    return output
end
local function file_digest(path: string): string
    local executor = assert(exec.get("bee.placement.native:executor"))
    local proc = assert(executor:exec("cat " .. path))
    local stdout = proc:stdout_stream()
    assert(proc:start())
    local content = ""
    while true do
        local chunk: unknown = stdout:read(65536)
        if type(chunk) ~= "string" or chunk == "" then break end
        content = content .. (chunk :: string)
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
    local data = entry.data :: Object
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
    local raw, err = funcs.new():with_actor(actor):with_scope(scope(carrier_scope)):call("bee.placement.native:measure_executable", {path = path})
    if err then error("measure executable: " .. tostring(err)) end
    local reply = raw :: {ok: boolean, value: Object?}
    if reply.ok and reply.value then
        local measured = reply.value :: Object
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
    (record.data :: Object).acceptance = {schema_revision = "bee.permission-acceptance@2", binding_id = BINDING, profile_id = "batch", binding_digest = binding_digest, profile_digest = profile_digest,
        adapter_ref = ADAPTER, adapter_digest = pinned.digest, fixture_digest = fixture_digest, executable_revision = measure_executable(executable).revision, executable_kind = measure_executable(executable).kind, executable_digest = measure_executable(executable).digest, proof_revision = "bee.permission-proof@1", accepted_by = "bee.test.operator", accepted_at = "2026-09-09T00:00:00.000Z"}
    apply(record)
    local policy = registry.get(POLICY)
    if not policy then error("permission policy entry") end
    local data = policy.data :: Object
    data.executables = {claude = executable}
    data.permission_exchange = {adapter_ref = ADAPTER, acceptance_ref = ACCEPTANCE, fixture_digest = fixture_digest, approver_policy = APPROVER_POLICY, poll_ms = 2000, ttl_ms = 60000}
    apply(policy)
    -- Production-shaped policies: one naming the real adapter the profile
    -- pins, with an acceptance record this suite fills, and one naming the
    -- fixture adapter no profile pins.
    local real_entry = registry.get(REAL_ADAPTER)
    if not real_entry then error("real adapter entry") end
    local real_adapter, real_error = adapter.decode(REAL_ADAPTER, (real_entry.data :: Object).adapter)
    if not real_adapter then error(tostring(real_error)) end
    local streams, streams_error = env.get("bee.harness.catalog:fixture_streams")
    if streams_error or type(streams) ~= "string" then error("BEE_FIXTURE_STREAMS is not set for the test runtime") end
    local capture_digest = file_digest(streams .. "/claude/stream-json-2/control.jsonl")
    local production_record = registry.get(PRODUCTION_ACCEPTANCE)
    if not production_record then error("production acceptance entry") end
    local measured_fixture = measure_executable(executable)
    local production_acceptance = production_record.data :: Object
    production_acceptance.acceptance = {schema_revision = "bee.permission-acceptance@2", binding_id = BINDING, profile_id = "batch", binding_digest = binding_digest, profile_digest = profile_digest,
        adapter_ref = REAL_ADAPTER, adapter_digest = real_adapter.digest, fixture_digest = capture_digest, executable_revision = measured_fixture.revision, executable_kind = measured_fixture.kind,
        executable_digest = measured_fixture.digest, proof_revision = "bee.permission-proof@1", accepted_by = "bee.test.operator", accepted_at = "2026-09-09T00:00:00.000Z"}
    apply(production_record)
    local production = registry.get(PRODUCTION_POLICY)
    if not production then error("production policy entry") end
    local production_data = production.data :: Object
    production_data.executables = {claude = executable}
    production_data.permission_exchange = {adapter_ref = REAL_ADAPTER, acceptance_ref = PRODUCTION_ACCEPTANCE, fixture_digest = capture_digest, approver_policy = APPROVER_POLICY, poll_ms = 2000, ttl_ms = 60000}
    apply(production)
    local unpinned = registry.get(UNPINNED_POLICY)
    if not unpinned then error("unpinned policy entry") end
    local unpinned_data = unpinned.data :: Object
    unpinned_data.executables = {claude = executable}
    unpinned_data.permission_exchange = {adapter_ref = ADAPTER, acceptance_ref = ACCEPTANCE, fixture_digest = fixture_digest, approver_policy = APPROVER_POLICY, poll_ms = 2000, ttl_ms = 60000}
    apply(unpinned)
    local policies_entry = registry.get("bee.approvals:approver_policies")
    if not policies_entry then error("approver policies entry") end
    local list = (policies_entry.data :: Object).policies :: {Object}
    local present = false
    for _, item in ipairs(list) do
        if item.name == APPROVER_POLICY then present = true end
    end
    if not present then
        list[#list + 1] = {name = APPROVER_POLICY, approvers = {APPROVER}, max_ttl_ms = 60000}
        apply(policies_entry)
    end
    local roots = registry.get("bee.placement.native:admitted_roots")
    if not roots then error("admitted roots entry") end
    local root_list = (roots.data :: Object).roots :: {Object}
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
    local created = call("bee.threads.service:create", {thread_id = fresh("thread"), idempotency_key = fresh("key"), title = "Permission carrier"})
    return created.thread_id :: string
end
local function request(thread_id: string, attempt_id: string, workspace: string, stream: string, timeout: string): Object
    return {thread_id = thread_id, action_id = "action-" .. attempt_id, attempt_id = attempt_id, owner_id = ACTOR, owner_incarnation = 1, binding_ref = BINDING,
        profile_id = "batch", brief = "read the notes", policy_ref = POLICY, resources = {{name = "project", grant_ref = "host", root_ref = ROOT, subpath = "", access = "write", purpose = "project"}},
        environment = {BEE_FIXTURE_STREAM = stream, BEE_FIXTURE_PERMISSION = REQUEST_ID, BEE_FIXTURE_PERMISSION_TIMEOUT = timeout}, working_directory = "project", workspace_id = workspace}
end
local function spawn_carrier(entry: string, request_value: Object, mode: string, crash_after: string?, pause_after: string?): string
    local spawner = process.with_context({}):with_actor(actor):with_scope(scope(carrier_scope))
    local pid, err = spawner:spawn_monitored(entry, "bee:workers", request_value, mode, process.pid(), crash_after, nil, pause_after)
    if not pid then error("spawn carrier: " .. tostring(err)) end
    return tostring(pid)
end
local exited: {[string]: Outcome} = {}
local function await_carriers(pids: {string}, label: string?): {[string]: Outcome}
    local events = assert(process.events())
    local deadline = time.after("60s")
    local function all_done(): boolean
        for _, pid in ipairs(pids) do
            if not exited[pid] then return false end
        end
        return true
    end
    while not all_done() do
        local selected = channel.select({events:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then error((label or "carrier") .. " did not finish") end
        local event = selected.value
        if event.kind == process.event.EXIT then
            local result = event.result or {}
            local value: Object? = nil
            if type(result.value) == "table" then value = result.value :: Object end
            exited[tostring(event.from)] = {value = value, error = result.error and tostring(result.error) or nil}
        end
    end
    local outcomes: {[string]: Outcome} = {}
    for _, pid in ipairs(pids) do outcomes[pid] = exited[pid] end
    return outcomes
end
local function await_carrier(pid: string, label: string?): Outcome
    return await_carriers({pid}, label)[pid] :: Outcome
end
-- The approver's side: catch up on the workspace inbox until the request
-- is pending, then decide it for the recorded proposal digest.
local function await_request(workspace: string): Object
    for _ = 1, 200 do
        local page = approve_call("bee.approvals:inbox", {workspace_id = workspace})
        for _, change in ipairs(page.changes :: {Object}) do
            local view = change.request :: Object
            if view.state == "pending" then return view end
        end
        time.sleep("50ms")
    end
    error("no pending approval request in workspace " .. workspace)
end
local function decide(view: Object, decision: string)
    approve_call("bee.approvals:decide", {approval_id = view.approval_id, expected_revision = view.revision, decision = decision, proposal_digest = view.proposal_digest})
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
local function payloads(records: {Object}, event_name: string): {Object}
    local found: {Object} = {}
    for _, item in ipairs(records) do
        local body = item.body :: Object
        if body.type == "extension" then
            local data = body.data :: Object
            if data.event_name == event_name then found[#found + 1] = json.decode(tostring(data.payload_json)) :: Object end
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
        local body = item.body :: Object
        if body.type == "tool.result" then
            local data = body.data :: Object
            if data.call_id == REQUEST_ID then total = total + 1 end
        end
    end
    return total
end
local function stderr_mentions(records: {Object}, marker: string): integer
    local total = 0
    for _, item in ipairs(records) do
        local body = item.body :: Object
        if body.type == "notice" then
            local data = body.data :: Object
            local content = bounds_text(data.content)
            if data.code == "stderr" and content:find(marker, 1, true) then total = total + 1 end
        end
    end
    return total
end
function bounds_text(value: unknown): string
    if type(value) ~= "table" then return "" end
    return tostring((value :: Object).text or "")
end
local function now_ms(): integer
    return math.floor(time.now():unix_nano() / 1000000)
end
local function hint(pid: string, thread_id: string)
    process.send(pid, "bee.carrier.hints." .. pid, {woke = true, thread_id = thread_id})
end
local function settlement_of(outcome: Outcome, label: string): Object
    if not outcome.value then error(label .. ": " .. tostring(outcome.error)) end
    return outcome.value.settlement :: Object
end
local function approvals_in(workspace: string): integer
    local listed = call("bee.approvals:list", {workspace_id = workspace})
    return #(listed.requests :: {unknown})
end
local function define_tests()
    test.describe("Carrier permission exchange", function()
        local stream = prepare_host()
        test.it("asks, waits, consumes and answers an allowed request through one deterministic write, woken by a hint rather than the poll", function()
            local thread_id, workspace, attempt_id = thread(), fresh("ws"), fresh("attempt")
            local pid = spawn_carrier("bee.harness.carrier:process", request(thread_id, attempt_id, workspace, stream, "8"), "open", nil)
            local view = await_request(workspace)
            test.eq(view.request_kind, "permission")
            test.eq((view.proposal :: Object).kind, "attempt")
            for _ = 1, 3 do hint(pid, thread_id) end
            local decided_at = now_ms()
            decide(view, "approved")
            for _ = 1, 3 do hint(pid, thread_id) end
            local settlement = settlement_of(await_carrier(pid), "allow run")
            test.is_true(now_ms() - decided_at < 1800)
            test.eq(settlement.outcome, "succeeded")
            test.eq(settlement.answer, "The file says: hello from notes")
            local records = records_of(thread_id)
            local list = phases(records)
            for _, phase in ipairs({"intended", "requested", "decided", "consumed", "acknowledged"}) do test.eq(count(list, phase), 1) end
            test.eq(count(list, "revalidated"), 0)
            test.eq(table.concat(writes(records), ","), "intended,accepted")
            test.eq(tool_results(records), 1)
            test.eq(stderr_mentions(records, "malformed"), 0)
            local consumed = approve_call("bee.approvals:read", {approval_id = view.approval_id})
            test.eq(consumed.consumer_id, ACTOR)
            test.eq(approvals_in(workspace), 1)
            -- The session ended the declared way: stdin closed at the
            -- owner's request and recorded, or the cooperative stop where
            -- the runtime cannot close stdin; either is on record apart
            -- from input acceptance and exit.
            local evidence: {string} = {}
            for _, item in ipairs(call("bee.placement.native:evidence", {attempt_id = attempt_id, limit = 64}).evidence :: {Object}) do evidence[#evidence + 1] = tostring(item.kind) end
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
            local launch = request(thread_id, fresh("attempt"), workspace, stream, "8")
            launch.policy_ref = UNPINNED_POLICY
            local unpinned = await_carrier(spawn_carrier("bee.harness.carrier:process", launch, "open", nil), "unpinned policy")
            test.is_nil(unpinned.value)
            if not tostring(unpinned.error):find("does not pin permission adapter", 1, true) then error("unpinned policy ended with: " .. tostring(unpinned.error)) end
            local pinned_thread, pinned_workspace = thread(), fresh("ws")
            local pinned_launch = request(pinned_thread, fresh("attempt"), pinned_workspace, stream, "8")
            pinned_launch.policy_ref = PRODUCTION_POLICY
            local outcome = await_carrier(spawn_carrier("bee.harness.carrier:process", pinned_launch, "open", nil), "production policy")
            test.is_nil(outcome.value)
            if not tostring(outcome.error):find("production exchange:", 1, true) then error("production policy ended with: " .. tostring(outcome.error)) end
            test.eq(#records_of(thread_id), 0)
            test.eq(#records_of(pinned_thread), 0)
        end)
        test.it("answers a denied request and records the terminal denial as its acknowledgment", function()
            local thread_id, workspace = thread(), fresh("ws")
            local pid = spawn_carrier("bee.harness.carrier:process", request(thread_id, fresh("attempt"), workspace, stream, "8"), "open", nil)
            decide(await_request(workspace), "denied")
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
                local launch = request(thread_id, fresh("attempt"), workspace, stream, "12")
                local first = spawn_carrier("bee.harness.catalog:carrier_faulted", launch, "open", crash)
                local decided_before = crash == "permission_consumed" or crash == "write_intended" or crash == "write_dispatched"
                if decided_before then decide(await_request(workspace), "approved") end
                local crashed = await_carrier(first, crash)
                test.is_true(tostring(crashed.error):find("crash after " .. crash, 1, true) ~= nil)
                local resumed = spawn_carrier("bee.harness.catalog:carrier_faulted", launch, "resume", nil)
                if not decided_before then decide(await_request(workspace), "approved") end
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
            local launch = request(thread_id, fresh("attempt"), workspace, stream, "12")
            local pid = spawn_carrier("bee.harness.catalog:carrier_faulted", launch, "open", nil, "permission_revalidated")
            local view = await_request(workspace)
            local db = assert(approvals.open())
            assert(approvals.establish(db))
            decide(view, "approved")
            time.sleep("1500ms")
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
            local launch = request(thread_id, fresh("attempt"), workspace, stream, "12")
            local pid = spawn_carrier("bee.harness.catalog:carrier_faulted", launch, "open", nil, "hints_opened")
            time.sleep("1500ms")
            local stored = call("bee.threads.carrier:checkpoint", {thread_id = thread_id, attempt_id = launch.attempt_id :: string})
            local point = stored.checkpoint :: Object
            local subscription_id = tostring(point.hint_subscription)
            test.is_true(#subscription_id > 0)
            call("bee.threads.delivery:unsubscribe", {thread_id = thread_id, idempotency_key = fresh("key"), subscription_id = subscription_id})
            process.send(pid, "bee.carrier.continue", {go = true})
            local view = await_request(workspace)
            decide(view, "approved")
            local settlement = settlement_of(await_carrier(pid, "lost subscription"), "lost subscription")
            test.eq(settlement.outcome, "succeeded")
            local records = records_of(thread_id)
            test.eq(count(phases(records), "consumed"), 1)
            test.eq(tool_results(records), 1)
        end)
        test.it("refuses to dispatch after recovery when the launch policy no longer measures as planned", function()
            local thread_id, workspace = thread(), fresh("ws")
            local launch = request(thread_id, fresh("attempt"), workspace, stream, "12")
            local first = spawn_carrier("bee.harness.catalog:carrier_faulted", launch, "open", "permission_consumed")
            decide(await_request(workspace), "approved")
            local crashed = await_carrier(first, "permission_consumed")
            test.is_true(tostring(crashed.error):find("crash after permission_consumed", 1, true) ~= nil)
            local policy = registry.get(POLICY)
            if not policy then error("permission policy entry") end
            local data = policy.data :: Object
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
            local data = policy.data :: Object
            data.executables = {claude = shell("pwd"):gsub("%s+$", "") .. "/" .. copy}
            apply(policy)
            return copy, original
        end
        local function unbind_copy(original: string, copy: string)
            local policy = registry.get(POLICY)
            if not policy then error("permission policy entry") end
            local data = policy.data :: Object
            data.executables = {claude = original}
            apply(policy)
            shell("rm -f " .. copy)
        end
        test.it("refuses to dispatch after recovery when the executable no longer measures as accepted, keeping the decision", function()
            local copy, original = bind_copy()
            local thread_id, workspace = thread(), fresh("ws")
            local launch = request(thread_id, fresh("attempt"), workspace, stream, "12")
            local first = spawn_carrier("bee.harness.catalog:carrier_faulted", launch, "open", "permission_consumed")
            local view = await_request(workspace)
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
            local record = approve_call("bee.approvals:read", {approval_id = view.approval_id})
            test.eq(record.decision, "approved")
            test.eq(record.decider_id, APPROVER)
        end)
        test.it("refuses to dispatch when the plan changed between revalidation and consumption under a restarted authority", function()
            local copy, original = bind_copy()
            local thread_id, workspace = thread(), fresh("ws")
            local launch = request(thread_id, fresh("attempt"), workspace, stream, "12")
            local pid = spawn_carrier("bee.harness.catalog:carrier_faulted", launch, "open", nil, "permission_revalidated")
            local view = await_request(workspace)
            local db = assert(approvals.open())
            assert(approvals.establish(db))
            decide(view, "approved")
            time.sleep("1500ms")
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
            local record = approve_call("bee.approvals:read", {approval_id = view.approval_id})
            test.eq(record.decision, "approved")
        end)
        test.it("leaves a write uncertain when the runner is lost during recovery and sends nothing after settlement", function()
            local thread_id, workspace = thread(), fresh("ws")
            local launch = request(thread_id, fresh("attempt"), workspace, stream, "1")
            local first = spawn_carrier("bee.harness.catalog:carrier_faulted", launch, "open", "write_intended")
            decide(await_request(workspace), "approved")
            local crashed = await_carrier(first, "write_intended")
            test.is_true(tostring(crashed.error):find("crash after write_intended", 1, true) ~= nil)
            time.sleep("2500ms")
            local settlement = settlement_of(await_carrier(spawn_carrier("bee.harness.catalog:carrier_faulted", launch, "resume", nil), "lost runner"), "lost runner")
            test.neq(settlement.outcome, "succeeded")
            local records = records_of(thread_id)
            test.eq(table.concat(writes(records), ","), "intended,uncertain")
            test.eq(tool_results(records), 0)
            local late_thread, late_workspace = thread(), fresh("ws")
            local late_launch = request(late_thread, fresh("attempt"), late_workspace, stream, "1")
            local paused = spawn_carrier("bee.harness.catalog:carrier_faulted", late_launch, "open", "permission_requested")
            local late_view = await_request(late_workspace)
            await_carrier(paused, "permission_requested")
            time.sleep("2500ms")
            decide(late_view, "approved")
            local late = settlement_of(await_carrier(spawn_carrier("bee.harness.catalog:carrier_faulted", late_launch, "resume", nil), "late decision"), "late decision")
            test.neq(late.outcome, "succeeded")
            local late_records = records_of(late_thread)
            test.eq(#writes(late_records), 0)
            test.eq(count(phases(late_records), "closed"), 1)
            test.eq(tool_results(late_records), 0)
            local projected = 0
            for _ = 1, 60 do
                projected = 0
                for _, item in ipairs(records_of(late_thread)) do
                    if item.kind == "approval.transition" then projected = projected + 1 end
                end
                if projected > 0 then break end
                time.sleep("100ms")
            end
            test.eq(projected, 1)
        end)
    end)
end
return test.run_cases(define_tests)
