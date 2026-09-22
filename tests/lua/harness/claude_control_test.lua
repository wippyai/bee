-- MIT. The carrier's permission exchange against the real Claude
-- executable: the harness runs through placement with the driver's
-- exchange launch, a scripted loopback endpoint answers one Bash tool_use,
-- the control request becomes a checkpointed intent and an approval, the
-- decision is consumed and answered through one write, and the harness
-- acknowledges it: an allow runs the action once in the project, a deny
-- runs nothing and is acknowledged by the correlated failed tool result,
-- and an approval left to expire is answered as a deny. Without the
-- executable the gate is reported open.
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
local launch = require("launch")
local placement_fixture = require("placement_fixture")
local ACTOR = "bee.test.claude_control"
local APPROVER = "bee.test.approver"
local POLICY = "bee.harness.catalog:claude_control_fixture_policy"
local ADAPTER = "bee.driver.claude:permission_adapter"
local ACCEPTANCE = "bee.harness.catalog:claude_control_acceptance"
local APPROVER_POLICY = "claude-control"
local ROOT = "bee.harness.catalog:project_fixture"
local PROJECT = ".wippy/carrier-project"
local BINDING = "bee.driver.claude:binding"
local SENTINEL = "sk-ant-sentinel-bee-000"
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
        local found, err = security.policy(name)
        if err or not found then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = found
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
    assert(proc:start())
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
local function claude_bin(): string?
    local bin, err = env.get("bee.harness.catalog:claude_bin")
    if err or type(bin) ~= "string" or bin == "" then return nil end
    return bin
end
local function fixture_bin(): string
    local bin, err = env.get("bee.harness.catalog:fixture_bin")
    if err or type(bin) ~= "string" or bin == "" then error("BEE_FIXTURE_BIN is not set for the test runtime") end
    return bin
end
local function capture_digest(): string
    local streams, streams_error = env.get("bee.harness.catalog:fixture_streams")
    if streams_error or type(streams) ~= "string" or streams == "" then error("BEE_FIXTURE_STREAMS is not set for the test runtime") end
    local sum, hash_error = hash.sha256(shell("cat " .. streams .. "/claude/stream-json-2/control.jsonl"))
    if not sum then error("digest the capture: " .. tostring(hash_error)) end
    return sum
end
local function real_adapter(): adapter.Adapter
    local entry = registry.get(ADAPTER)
    if not entry then error("adapter entry") end
    local decoded, err = adapter.decode(ADAPTER, (entry.data :: Object).adapter)
    if not decoded then error(tostring(err)) end
    return decoded
end
local endpoint_handle: any = nil
local endpoint_executor: any = nil
local function start_endpoint(record: string, command: string): string
    local executor = assert(exec.get("bee.placement.native:executor"))
    local proc, err = executor:exec(fixture_bin() .. "/gateway-client endpoint " .. record, {env = {BEE_ENDPOINT_TOOL = command}})
    if not proc then error("endpoint: " .. tostring(err)) end
    assert(proc:start())
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
-- The host side: bind the executable and the endpoint through the policy,
-- record acceptance for the measured binding, profile, adapter and capture,
-- admit the approver and the project root.
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
local function prepare_host(claude: string, port: string, ttl_ms: integer)
    local pinned = real_adapter()
    local snapshot = assert(catalog.snapshot())
    local usable = assert(catalog.usable(snapshot))
    local binding_digest, profile_digest = "", ""
    for _, candidate in ipairs(usable) do
        if candidate.binding_id == BINDING then binding_digest, profile_digest = candidate.binding_digest.entry, candidate.profile_digest.entry end
    end
    if binding_digest == "" then error("the Claude binding is not usable on this host") end
    local fixture_digest = capture_digest()
    local record = registry.get(ACCEPTANCE)
    if not record then error("acceptance entry") end
    (record.data :: Object).acceptance = {schema_revision = "bee.permission-acceptance@2", binding_id = BINDING, profile_id = "batch", binding_digest = binding_digest, profile_digest = profile_digest,
        adapter_ref = ADAPTER, adapter_digest = pinned.digest, fixture_digest = fixture_digest, executable_revision = measure_executable(claude).revision, executable_kind = measure_executable(claude).kind, executable_digest = measure_executable(claude).digest, proof_revision = "bee.permission-proof@1", accepted_by = "bee.test.operator", accepted_at = "2026-09-09T00:00:00.000Z"}
    apply(record)
    local policy = registry.get(POLICY)
    if not policy then error("policy entry") end
    local data = policy.data :: Object
    data.executables = {claude = claude}
    data.environment = {ANTHROPIC_BASE_URL = "http://127.0.0.1:" .. port}
    data.permission_exchange = {adapter_ref = ADAPTER, acceptance_ref = ACCEPTANCE, fixture_digest = fixture_digest, approver_policy = APPROVER_POLICY, poll_ms = 500, ttl_ms = ttl_ms}
    apply(policy)
    local policies_entry = registry.get("bee:approver_policies")
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
end
local function thread(): string
    local created = call("bee.threads.service:create", {thread_id = fresh("thread"), idempotency_key = fresh("key"), title = "Claude control"})
    return created.thread_id :: string
end
local function request(thread_id: string, attempt_id: string, workspace: string): Object
    local placement = placement_fixture.resolve()
    return {thread_id = thread_id, action_id = "action-" .. attempt_id, attempt_id = attempt_id, owner_id = ACTOR, owner_incarnation = 1, binding_ref = BINDING,
        profile_id = "batch", brief = "leave a marker", policy_ref = POLICY, resources = {{name = "project", grant_ref = "host", root_ref = ROOT, subpath = "", access = "write", purpose = "project"}},
        environment = {PATH = "/usr/bin:/bin", ANTHROPIC_API_KEY = SENTINEL}, working_directory = "project", workspace_id = workspace,
        placement_binding_ref = placement.binding_id, placement_binding_digest = placement.binding_digest}
end
local function spawn_carrier(request_value: Object): string
    local spawner = process.with_context({}):with_actor(actor):with_scope(scope(carrier_scope))
    local pid, err = spawner:spawn_monitored("bee.harness.carrier:process", "bee:workers", request_value, "open", process.pid())
    if not pid then error("spawn carrier: " .. tostring(err)) end
    return tostring(pid)
end
-- The faulted carrier runs the production machine with a crash or pause
-- barrier, for the recovery matrix.
local function spawn_faulted(request_value: Object, mode: string, crash_after: string?, pause_after: string?): string
    local spawner = process.with_context({}):with_actor(actor):with_scope(scope(carrier_scope))
    local pid, err = spawner:spawn_monitored("bee.harness.catalog:carrier_faulted", "bee:workers", request_value, mode, process.pid(), crash_after, nil, pause_after)
    if not pid then error("spawn faulted carrier: " .. tostring(err)) end
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
local function await_request(workspace: string): Object
    for _ = 1, 400 do
        local page = approve_call("bee.approvals.binding:inbox", {workspace_id = workspace})
        for _, change in ipairs(page.changes :: {Object}) do
            local view = change.request :: Object
            if view.state == "pending" then return view end
        end
        time.sleep("50ms")
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
        local page = call("bee.threads.service:read_after", {thread_id = thread_id, cursor = cursor, limit = 64})
        for _, item in ipairs(page.records :: {Object}) do all[#all + 1] = item end
        if page.has_more ~= true then break end
        cursor = math.floor(page.scanned_through :: number)
    end
    return all
end
local function phases(records: {Object}): {string}
    local list: {string} = {}
    for _, item in ipairs(records) do
        local body = item.body :: Object
        if body.type == "extension" then
            local data = body.data :: Object
            if data.event_name == "bee.carrier.permission" then list[#list + 1] = tostring((json.decode(tostring(data.payload_json)) :: Object).phase) end
        end
    end
    return list
end
local function writes(records: {Object}): {string}
    local list: {string} = {}
    for _, item in ipairs(records) do
        local body = item.body :: Object
        if body.type == "extension" then
            local data = body.data :: Object
            if data.event_name == "bee.carrier.write" then list[#list + 1] = tostring((json.decode(tostring(data.payload_json)) :: Object).phase) end
        end
    end
    return list
end
local function approvals_in(workspace: string): integer
    local listed = call("bee.approvals.binding:list", {workspace_id = workspace})
    return #(listed.requests :: {unknown})
end
local function count(list: {string}, wanted: string): integer
    local total = 0
    for _, item in ipairs(list) do
        if item == wanted then total = total + 1 end
    end
    return total
end
local function tool_results(records: {Object}, outcome: string): integer
    local total = 0
    for _, item in ipairs(records) do
        local body = item.body :: Object
        if body.type == "tool.result" then
            local data = body.data :: Object
            if data.call_id == "toolu_bee_1" and data.outcome == outcome then total = total + 1 end
        end
    end
    return total
end
local function settlement_of(outcome: Outcome, label: string): Object
    if not outcome.value then error(label .. ": " .. tostring(outcome.error)) end
    return outcome.value.settlement :: Object
end
-- The effect is a counted append, so a duplicate execution is visible.
local function marker_count(name: string): integer
    return math.floor(tonumber(shell("cat " .. PROJECT .. "/" .. name .. " 2>/dev/null | wc -l"):match("%d+") or "0") or 0)
end
local function define_tests()
    test.describe("Carrier permission exchange with the real Claude executable", function()
        test.it("asks, answers and acknowledges allow, deny and expiry through placement, or reports the gate open", function()
            local claude = claude_bin()
            if not claude then
                test.eq(launch.CLAUDE_AUTHENTICATION, "unproven")
                return
            end
            if not shell(claude .. " --version"):find("Claude Code", 1, true) then error("not the Claude executable") end
            local root = ".wippy/claude-control-" .. fresh("run")
            shell("mkdir -p " .. root)
            local function run(name: string, ttl_ms: integer, act: (string) -> ()): ({Object}, Object)
                local marker = "proof-" .. name .. "-" .. fresh("m") .. ".txt"
                local record = root .. "/" .. name .. ".jsonl"
                local port = start_endpoint(record, "echo bee >> " .. marker)
                prepare_host(claude, port, ttl_ms)
                local thread_id, workspace = thread(), fresh("ws")
                local attempt_id = fresh("attempt")
                local pid = spawn_carrier(request(thread_id, attempt_id, workspace))
                act(workspace)
                local settlement = settlement_of(await_carrier(pid, name), name)
                stop_endpoint()
                local records = records_of(thread_id)
                for _, item in ipairs(records) do
                    test.is_nil(json.encode(item):find(SENTINEL, 1, true))
                end
                local recorded = shell("cat " .. record)
                if not recorded:find('"x_api_key": "' .. SENTINEL .. '"', 1, true) then error(name .. ": the endpoint saw no api key") end
                settlement.effects = marker_count(marker)
                shell("rm -f " .. PROJECT .. "/" .. marker)
                local evidence: {string} = {}
                for _, item in ipairs(call("bee.placement.native:evidence", {attempt_id = attempt_id, limit = 64}).evidence :: {Object}) do evidence[#evidence + 1] = tostring(item.kind) end
                local input_phases: {string} = {}
                for _, item in ipairs(records) do
                    local body = item.body :: Object
                    if body.type == "extension" then
                        local data = body.data :: Object
                        if data.event_name == "bee.carrier.input" then input_phases[#input_phases + 1] = tostring((json.decode(tostring(data.payload_json)) :: Object).phase) end
                    end
                end
                if count(evidence, "stdin.closed") == 1 then
                    settlement.session_end = "closed:" .. table.concat(input_phases, ",")
                else
                    settlement.session_end = "stopped:" .. tostring(count(evidence, "stdin.uncertain")) .. ":" .. tostring(count(evidence, "stop.requested")) .. ":" .. table.concat(input_phases, ",")
                end
                settlement.exited = count(evidence, "child.exited")
                settlement.measured = count(evidence, "executable.measured")
                return records, settlement
            end
            local allowed, allow_settlement = run("allow", 60000, function(workspace: string)
                local view = await_request(workspace)
                test.eq(view.request_kind, "permission")
                decide(view, "approved")
            end)
            test.eq(allow_settlement.outcome, "succeeded")
            test.eq(allow_settlement.effects, 1)
            test.eq(allow_settlement.exited, 1)
            -- Where this runtime measures the executable, the plan carried
            -- the measurement and the runner verified it before exec.
            if executable_digest(claude) ~= string.rep("0", 64) then test.eq(allow_settlement.measured, 1) else test.eq(allow_settlement.measured, 0) end
            if allow_settlement.session_end ~= "closed:close_intended,closed" and allow_settlement.session_end ~= "stopped:1:1:close_intended,close_uncertain" then
                error("session end: " .. tostring(allow_settlement.session_end))
            end
            local allow_phases = phases(allowed)
            for _, phase in ipairs({"intended", "requested", "decided", "consumed", "acknowledged"}) do test.eq(count(allow_phases, phase), 1) end
            test.eq(tool_results(allowed, "succeeded"), 1)
            test.eq(tool_results(allowed, "failed"), 0)
            local denied, deny_settlement = run("deny", 60000, function(workspace: string)
                decide(await_request(workspace), "denied")
            end)
            test.eq(deny_settlement.effects, 0)
            local deny_phases = phases(denied)
            test.eq(count(deny_phases, "consumed"), 0)
            test.eq(count(deny_phases, "declined"), 1)
            test.eq(count(deny_phases, "acknowledged"), 1)
            test.eq(tool_results(denied, "failed"), 1)
            test.eq(tool_results(denied, "succeeded"), 0)
            local expired, expiry_settlement = run("expiry", 1500, function(workspace: string)
                await_request(workspace)
            end)
            test.eq(expiry_settlement.effects, 0)
            test.eq(count(phases(expired), "consumed"), 0)
            test.eq(count(phases(expired), "declined"), 1)
            test.eq(count(phases(expired), "acknowledged"), 1)
            test.eq(tool_results(expired, "failed"), 1)
            test.eq(tool_results(expired, "succeeded"), 0)
            shell("rm -rf " .. root)
            test.eq(launch.CLAUDE_AUTHENTICATION, "unproven")
        end)
        test.it("recovers every boundary with one approval, one response and one effect against the executable, and loses nothing to a lost runner, a takeover or a late decision", function()
            local claude = claude_bin()
            if not claude then
                test.eq(launch.CLAUDE_AUTHENTICATION, "unproven")
                return
            end
            local root = ".wippy/claude-matrix-" .. fresh("run")
            shell("mkdir -p " .. root)
            -- Each case gets its own endpoint and marker; the host is
            -- prepared once per endpoint since the policy names its port.
            local function open_case(name: string): (string, string, string, string, Object)
                local marker = "proof-" .. name .. "-" .. fresh("m") .. ".txt"
                local port = start_endpoint(root .. "/" .. name .. ".jsonl", "echo bee >> " .. marker)
                prepare_host(claude, port, 60000)
                local thread_id, workspace, attempt_id = thread(), fresh("ws"), fresh("attempt")
                return marker, thread_id, workspace, attempt_id, request(thread_id, attempt_id, workspace)
            end
            local function finish(marker: string): integer
                stop_endpoint()
                local effects = marker_count(marker)
                shell("rm -f " .. PROJECT .. "/" .. marker)
                return effects
            end
            for _, crash in ipairs({"permission_intended", "approval_created", "permission_requested", "permission_consumed", "write_intended", "write_dispatched"}) do
                local marker, thread_id, workspace, _, launch_request = open_case(crash)
                local first = spawn_faulted(launch_request, "open", crash, nil)
                local decided_before = crash == "permission_consumed" or crash == "write_intended" or crash == "write_dispatched"
                if decided_before then decide(await_request(workspace), "approved") end
                local crashed = await_carrier(first, crash)
                test.is_true(tostring(crashed.error):find("crash after " .. crash, 1, true) ~= nil)
                local resumed = spawn_faulted(launch_request, "resume", nil, nil)
                if not decided_before then decide(await_request(workspace), "approved") end
                local settlement = settlement_of(await_carrier(resumed, crash .. " resume"), crash)
                local effects = finish(marker)
                local records = records_of(thread_id)
                if settlement.outcome ~= "succeeded" then
                    error(crash .. ": settled " .. tostring(settlement.outcome) .. " (" .. tostring(settlement.reason) .. "); phases " .. table.concat(phases(records), ",") .. "; writes " .. table.concat(writes(records), ","))
                end
                test.eq(effects, 1)
                test.eq(approvals_in(workspace), 1)
                test.eq(count(phases(records), "consumed"), 1)
                test.eq(count(phases(records), "acknowledged"), 1)
                test.eq(table.concat(writes(records), ","), "intended,accepted")
                test.eq(tool_results(records, "succeeded"), 1)
                test.eq(tool_results(records, "failed"), 0)
                for _, item in ipairs(records) do
                    test.is_nil(json.encode(item):find(SENTINEL, 1, true))
                end
            end
            -- Authority restart between revalidation and consumption.
            do
                local marker, thread_id, workspace, _, launch_request = open_case("authority")
                local pid = spawn_faulted(launch_request, "open", nil, "permission_revalidated")
                local view = await_request(workspace)
                local db = assert(approvals.open())
                assert(approvals.establish(db))
                decide(view, "approved")
                time.sleep("1500ms")
                assert(approvals.establish(db))
                db:release()
                process.send(pid, "bee.carrier.continue", {go = true})
                local settlement = settlement_of(await_carrier(pid, "authority restart"), "authority restart")
                local effects = finish(marker)
                test.eq(settlement.outcome, "succeeded")
                test.eq(effects, 1)
                local records = records_of(thread_id)
                test.eq(count(phases(records), "revalidated"), 2)
                test.eq(count(phases(records), "consumed"), 1)
                test.eq(tool_results(records, "succeeded"), 1)
            end
            -- Runner lost before dispatch: the write is uncertain, nothing
            -- is resent, no effect happens.
            do
                local marker, thread_id, workspace, attempt_id, launch_request = open_case("lost")
                local first = spawn_faulted(launch_request, "open", "write_intended", nil)
                decide(await_request(workspace), "approved")
                await_carrier(first, "write_intended")
                call("bee.placement.native:stop", {attempt_id = attempt_id, mode = "forced"})
                time.sleep("1500ms")
                local settlement = settlement_of(await_carrier(spawn_faulted(launch_request, "resume", nil, nil), "lost runner"), "lost runner")
                local effects = finish(marker)
                test.neq(settlement.outcome, "succeeded")
                test.eq(effects, 0)
                local records = records_of(thread_id)
                test.eq(table.concat(writes(records), ","), "intended,uncertain")
                test.eq(tool_results(records, "succeeded"), 0)
            end
            -- Runner lost after dispatch with the acceptance unresolved: the
            -- write stays uncertain, nothing is resent, and the effect
            -- happened at most once.
            do
                local marker, thread_id, workspace, attempt_id, launch_request = open_case("lost_after")
                local first = spawn_faulted(launch_request, "open", "write_dispatched", nil)
                decide(await_request(workspace), "approved")
                await_carrier(first, "write_dispatched")
                -- The runner itself is lost, so no remembered acceptance
                -- survives; the child is then stopped through placement.
                local status = call("bee.placement.native:status", {attempt_id = attempt_id})
                local runner = tostring((status.attempt :: Object).runner or "")
                if runner == "" then error("no runner recorded for the attempt") end
                assert(process.terminate(runner))
                time.sleep("500ms")
                call("bee.placement.native:stop", {attempt_id = attempt_id, mode = "forced"})
                time.sleep("1500ms")
                local settlement = settlement_of(await_carrier(spawn_faulted(launch_request, "resume", nil, nil), "lost after dispatch"), "lost after dispatch")
                local effects = finish(marker)
                test.neq(settlement.outcome, "succeeded")
                test.is_true(effects <= 1)
                local records = records_of(thread_id)
                test.eq(table.concat(writes(records), ","), "intended,uncertain")
                test.eq(tool_results(records, "succeeded"), 0)
            end
            -- Takeover: a replacement claims the attempt while the old
            -- carrier waits; the old one is fenced, one response goes out,
            -- the effect happens once.
            do
                local marker, thread_id, workspace, _, launch_request = open_case("takeover")
                local old = spawn_faulted(launch_request, "open", nil, "permission_requested")
                local view = await_request(workspace)
                local replacement = spawn_faulted(launch_request, "resume", nil, nil)
                time.sleep("1000ms")
                decide(view, "approved")
                process.send(old, "bee.carrier.continue", {go = true})
                local stale = await_carrier(old, "old carrier")
                test.is_nil(stale.value)
                if not tostring(stale.error):find("CONFLICT", 1, true) then error("old carrier ended with: " .. tostring(stale.error)) end
                local settlement = settlement_of(await_carrier(replacement, "replacement"), "replacement")
                local effects = finish(marker)
                test.eq(settlement.outcome, "succeeded")
                test.eq(effects, 1)
                local records = records_of(thread_id)
                test.eq(table.concat(writes(records), ","), "intended,accepted")
                test.eq(tool_results(records, "succeeded"), 1)
                test.eq(approvals_in(workspace), 1)
            end
            -- A decision after the attempt ended sends nothing.
            do
                local marker, thread_id, workspace, attempt_id, launch_request = open_case("late")
                local paused = spawn_faulted(launch_request, "open", "permission_requested", nil)
                local view = await_request(workspace)
                await_carrier(paused, "permission_requested")
                call("bee.placement.native:stop", {attempt_id = attempt_id, mode = "forced"})
                time.sleep("1500ms")
                local settlement = settlement_of(await_carrier(spawn_faulted(launch_request, "resume", nil, nil), "ended attempt"), "ended attempt")
                test.neq(settlement.outcome, "succeeded")
                decide(view, "approved")
                time.sleep("500ms")
                local effects = finish(marker)
                test.eq(effects, 0)
                local records = records_of(thread_id)
                test.eq(#writes(records), 0)
                test.eq(count(phases(records), "closed"), 1)
                test.eq(tool_results(records, "succeeded"), 0)
            end
            shell("rm -rf " .. root)
        end)
    end)
end
return test.run_cases(define_tests)
