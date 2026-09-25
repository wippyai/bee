-- MIT. Production Claude inbox push through the fenced controller: a
-- non-fixture launch policy carrying a host push acceptance admits the
-- stream-json controller, and an inbox item committed while the turn runs
-- is injected as an identified user message between turns. Without the
-- acceptance the plan is refused before any launch. Against the real
-- pinned executable the suite proves admission; without it the gate is
-- reported open.
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
local system = require("system")
local exec = require("exec")
local hash = require("hash")
local catalog = require("catalog")
local adapter = require("adapter")
local launch = require("launch")
local placement_fixture = require("placement_fixture")
local sends = require("sends")
local ACTOR = "bee.test.push_production"
local TARGET_ACTOR = "bee.test.push_production.target"
local POLICY = "bee.harness.catalog:push_production_policy"
local ACCEPTANCE = "bee.harness.catalog:push_production_acceptance"
local ADAPTER = "bee.driver.claude:permission_adapter"
local BINDING = "bee.driver.claude:binding"
local ROOT = "bee.harness.catalog:project_fixture"
local CARRIER = "bee.harness.carrier:process"
type Object = {[string]: unknown}
local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end
local scope_names = {"bee.harness.catalog:carrier_client_policy", "bee.harness.catalog:gateway_client_policy", "bee.security.threads:thread_create_policy", "bee.security.threads:thread_observe_policy", "bee.security.threads:thread_lifecycle_policy",
    "bee.security.threads:thread_carrier_policy", "bee.security.harness:carrier_policy", "bee.harness.catalog:carrier_spawn_policy", "bee.security.gateway:gateway_manage_policy", "bee.security.gateway:gateway_admit_policy",
    "bee.harness.catalog:codex_credential_client_policy", "bee.security.credentials:credential_manage_policy", "bee.security.credentials:credential_issue_policy",
    "bee.harness.catalog:workspace_catalog_call_policy", "bee.security.storage:workspace_catalog_manage_policy",
    "bee.security.gateway:gateway_session_send_workspace_policy"}
local function scope(): security.Scope
    local policies: {security.Policy} = {}
    for index, name in ipairs(scope_names) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    return security.new_scope(policies)
end
local function call_as(actor_id: string, target: string, request: unknown, workspace_id: string?): Object
    local reply, err = funcs.new():with_actor(principals.actor(actor_id, workspace_id or principals.workspace(request))):with_scope(scope()):call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    local value = reply :: Object
    if value.ok ~= true then
        local fault = value.error :: Object
        error(target .. ": " .. tostring(fault.code) .. ": " .. tostring(fault.message))
    end
    return value.value :: Object
end
local function call(target: string, request: unknown): Object return call_as(ACTOR, target, request) end
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
local function admit_root()
    local catalog_roots = assert(registry.get("bee:resource_roots"))
    local available = (catalog_roots.data :: Object).roots :: {Object}
    local admitted = false
    for _, root in ipairs(available) do if root.root_ref == ROOT then admitted = true end end
    if not admitted then
        available[#available + 1] = {root_ref = ROOT, access = "write"}
        apply(catalog_roots)
    end
    local mode = assert(registry.get("bee:placement_resource_mode"))
    mode.data = {mode = "host_configured"}
    apply(mode)
    local entry = assert(registry.get("bee:placement_admitted_roots"))
    local roots = (entry.data :: Object).roots :: {Object}
    for _, root in ipairs(roots) do
        if root.root_ref == ROOT then return end
    end
    roots[#roots + 1] = {root_ref = ROOT, access = "write"}
    apply(entry)
end
local function file_digest(path: string): string
    local executor = assert(exec.get("bee:placement_executor"))
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
type Measured = {revision: string, kind: string, digest: string}
local function measure_executable(path: string): Measured
    local actor = security.new_actor(ACTOR)
    local raw, err = funcs.new():with_actor(actor):with_scope(scope()):call("bee.placement.native.binding:measure_executable", {path = path})
    if err then error("measure executable: " .. tostring(err)) end
    local reply = raw :: {ok: boolean, value: Object?}
    if reply.ok and reply.value then
        local measured = reply.value :: Object
        return {revision = tostring(measured.revision), kind = tostring(measured.kind), digest = tostring(measured.digest)}
    end
    return {revision = "bee.executable-measurement@1", kind = "other", digest = string.rep("0", 64)}
end
-- prepare_production: bind the pinned executable path the driver names and
-- record host acceptance for this snapshot's binding, profile, adapter and
-- proven push fixture. The acceptance covers the measured executable; the
-- plan refuses any revision, kind or digest swap at launch.
local function prepare_production(claude: string)
    admit_root()
    local snapshot = assert(catalog.snapshot())
    local usable = assert(catalog.usable(snapshot))
    local binding_digest, profile_digest = "", ""
    for _, candidate in ipairs(usable) do
        if candidate.binding_id == BINDING then binding_digest, profile_digest = candidate.binding_digest.entry, candidate.profile_digest.entry end
    end
    if binding_digest == "" then error("the Claude binding is not usable on this host") end
    local adapter_entry = registry.get(ADAPTER)
    if not adapter_entry then error("adapter entry") end
    local pinned, adapter_error = adapter.decode(ADAPTER, (adapter_entry.data :: Object).adapter)
    if not pinned then error(tostring(adapter_error)) end
    local streams = setting("bee.harness.catalog:fixture_streams", "BEE_FIXTURE_STREAMS")
    local fixture_digest = file_digest(streams .. "/claude/stream-json-2/plain.jsonl")
    local measured = measure_executable(claude)
    local record = registry.get(ACCEPTANCE)
    if not record then error("acceptance entry") end
    (record.data :: Object).acceptance = {schema_revision = "bee.permission-acceptance@2", binding_id = BINDING, profile_id = "batch", binding_digest = binding_digest, profile_digest = profile_digest,
        adapter_ref = ADAPTER, adapter_digest = pinned.digest, fixture_digest = fixture_digest, executable_revision = measured.revision, executable_kind = measured.kind,
        executable_digest = measured.digest, proof_revision = "bee.permission-proof@1", accepted_by = "bee.test.operator", accepted_at = "2026-09-09T00:00:00.000Z"}
    apply(record)
    local policy = registry.get(POLICY)
    if not policy then error("policy entry") end
    local data = policy.data :: Object
    data.executables = {claude = claude}
    data.push_acceptance = {adapter_ref = ADAPTER, acceptance_ref = ACCEPTANCE, fixture_digest = fixture_digest}
    apply(policy)
end
local function session(thread_id: string, workspace_id: string, environment: {[string]: string}, owner_id: string?): Object
    local placement = placement_fixture.resolve()
    local attempt_id = fresh("attempt")
    return {thread_id = thread_id, action_id = "action-" .. attempt_id, attempt_id = attempt_id, owner_id = owner_id or ACTOR, owner_incarnation = 1, binding_ref = BINDING,
        profile_id = "batch", brief = "leave a marker", policy_ref = POLICY, workspace_id = workspace_id,
        resources = {{name = "project", grant_ref = "host", root_ref = ROOT, subpath = "", access = "write", purpose = "project"}},
        environment = environment, working_directory = "project", placement_binding_ref = placement.binding_id, placement_binding_digest = placement.binding_digest}
end
local function spawn(request_value: Object): string
    local pid, err = process.with_context({}):with_actor(principals.actor(tostring(request_value.owner_id), request_value.workspace_id)):with_scope(scope()):spawn_monitored(CARRIER, "bee:workers", request_value, "open", process.pid())
    if not pid then error("spawn carrier: " .. tostring(err)) end
    return tostring(pid)
end
type Outcome = {value: Object?, error: string?}
local exited: {[string]: Outcome} = {}
local function observe_exit(pid: string): Outcome?
    local events = assert(process.events())
    local selected = channel.select({events:case_receive(), time.after("1s"):case_receive()})
    if not selected or not selected.ok then return exited[pid] end
    local event = selected.value
    if type(event) == "table" and event.kind == process.event.EXIT and tostring(event.from) == pid and not exited[pid] then
        local result = (event.result or {}) :: Object
        local value: Object? = nil
        if type(result.value) == "table" then value = result.value :: Object end
        exited[pid] = {value = value, error = result.error and tostring(result.error) or nil}
    end
    return exited[pid]
end
local function records_of(thread_id: string, actor_id: string?): {Object}
    local all: {Object} = {}
    local cursor = 0
    for _ = 1, 32 do
        local page = call_as(actor_id or ACTOR, "bee.threads.service:read_after", {thread_id = thread_id, cursor = cursor, limit = 64})
        for _, item in ipairs(page.records :: {Object}) do all[#all + 1] = item end
        if page.has_more ~= true then break end
        cursor = math.floor(page.scanned_through :: number)
    end
    return all
end
local function action_admitted(thread_id: string, action_id: string, actor_id: string): boolean
    for _, item in ipairs(records_of(thread_id, actor_id)) do
        if item.kind == "action.admitted" and item.action_id == action_id then return true end
    end
    return false
end
local function shell(command: string): string
    local executor = assert(exec.get("bee:placement_executor"))
    local proc, exec_error = executor:exec("sh -c '" .. command .. "'")
    if not proc then error("exec " .. command .. ": " .. tostring(exec_error)) end
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
local function claude_bin(): string?
    local bin, err = env.get("bee.harness.catalog:claude_bin")
    if err or type(bin) ~= "string" or bin == "" then return nil end
    return bin
end
local function define_tests()
    test.describe("Production Claude inbox push", function()
        test.it("refuses a production push without acceptance before any launch", function()
            admit_root()
            local bin = setting("bee.harness.catalog:fixture_bin", "BEE_FIXTURE_BIN")
            local policy = assert(registry.get(POLICY))
            local data = policy.data :: Object
            data.executables = {claude = bin .. "/claude"}
            apply(policy)
            local label = fresh("push-refused-ws")
            local workspace = tostring(call("bee.workspace.catalog:create", {label = label, root_ref = ROOT,
                subpath = label, create_directory = true}).workspace_id)
            local thread_id = tostring(call_as(TARGET_ACTOR, "bee.threads.service:create", {thread_id = fresh("push-refused-thread"),
                idempotency_key = fresh("key"), title = "Refused push"}, workspace).thread_id)
            local target = session(thread_id, workspace, {}, TARGET_ACTOR)
            local pid = spawn(target)
            local outcome: Outcome? = nil
            for _ = 1, 60 do
                outcome = observe_exit(pid)
                if outcome then break end
            end
            if not outcome then error("the refused carrier did not finish") end
            test.is_nil(outcome.value)
            if not tostring(outcome.error):find("inbox push needs a pinned executable acceptance before production admission", 1, true) then
                error("refused push ended with: " .. tostring(outcome.error))
            end
            test.eq(#records_of(thread_id, TARGET_ACTOR), 0)
        end)
        test.it("delivers a production inbox item between turns through the pinned executable, or stops at the environment measurement gate", function()
            local bin = setting("bee.harness.catalog:fixture_bin", "BEE_FIXTURE_BIN")
            local streams = setting("bee.harness.catalog:fixture_streams", "BEE_FIXTURE_STREAMS")
            prepare_production(bin .. "/claude")
            local label = fresh("push-prod-ws")
            local workspace = tostring(call("bee.workspace.catalog:create", {label = label, root_ref = ROOT,
                subpath = label, create_directory = true}).workspace_id)
            local target_thread = tostring(call_as(TARGET_ACTOR, "bee.threads.service:create", {thread_id = fresh("push-prod-target-thread"),
                idempotency_key = fresh("key"), title = "Production push target"}, workspace).thread_id)
            local source_thread = tostring(call_as(ACTOR, "bee.threads.service:create", {thread_id = fresh("push-prod-source-thread"),
                idempotency_key = fresh("key"), title = "Production push source"}, workspace).thread_id)
            local source_action = fresh("source-action")
            call_as(ACTOR, "bee.threads.service:admit_action", {thread_id = source_thread, action_id = source_action,
                idempotency_key = fresh("admit"), admitted = {request_id = fresh("source-request"), principal_id = ACTOR,
                    binding_ref = BINDING, binding_digest = "fixture-digest", grant_refs = {}, budget_ref = POLICY,
                    input = {text = "send an inbox item"}}}, workspace)
            local target = session(target_thread, workspace,
                {BEE_FIXTURE_STREAM = streams .. "/claude/stream-json-2/plain.jsonl", BEE_FIXTURE_PUSH = "1",
                    BEE_FIXTURE_PUSH_EXIT = "1"}, TARGET_ACTOR)
            local pid = spawn(target)
            local admitted = false
            local outcome: Outcome? = nil
            for _ = 1, 90 do
                outcome = observe_exit(pid)
                if outcome then break end
                if action_admitted(target_thread, tostring(target.action_id), TARGET_ACTOR) then admitted = true; break end
            end
            if outcome then
                -- The acceptance was admitted past the push gate; this host
                -- proves no read-only measurement volume, so the plan stops
                -- at the environment gate before any launch.
                test.is_nil(outcome.value)
                if not tostring(outcome.error):find("production push:", 1, true) then error("production policy ended with: " .. tostring(outcome.error)) end
                if tostring(outcome.error):find("acceptance", 1, true) then error("the acceptance was not admitted: " .. tostring(outcome.error)) end
                test.eq(#records_of(target_thread, TARGET_ACTOR), 0)
                return
            end
            if not admitted then error("the production carrier neither admitted its action nor finished") end
            call_as(TARGET_ACTOR, "bee.threads.service:inbox_accept", {thread_id = target_thread, action_id = target.action_id,
                sender_id = ACTOR, allow = true, expected_epoch = 0, idempotency_key = fresh("accept")}, workspace)
            local native = system.node.id()
            if not native or native == "" then error("native node identity is unavailable") end
            local message_id = fresh("message")
            local content = {text = "production push while busy"}
            local sent = call_as(ACTOR, "bee.threads.service:inbox_send", {thread_id = target_thread, target_action_id = target.action_id,
                sender_thread_id = source_thread, sender_action_id = source_action, node_id = native, grant_epoch = 1,
                idempotency_key = fresh("send"), message_id = message_id, content = content,
                payload_digest = sends.payload_digest({message_id = message_id, content = content})}, workspace)
            test.not_nil(sent.record_id)
            local accepted: Object? = nil
            for _ = 1, 150 do
                local page = call_as(TARGET_ACTOR, "bee.threads.service:inbox_list", {thread_id = target_thread,
                    action_id = target.action_id, after_sequence = 0, limit = 4}, workspace)
                local item = (page.items :: {Object})[1]
                if item and item.state == "transport_accepted" then accepted = item; break end
                time.sleep("100ms")
            end
            if not accepted then error("production Claude did not accept the pushed inbox transport") end
            test.eq(accepted.record_id, sent.record_id)
            test.eq(accepted.payload_digest, sent.payload_digest)
            local ack = call_as(TARGET_ACTOR, "bee.threads.service:inbox_ack", {thread_id = target_thread,
                action_id = target.action_id, inbox_sequence = sent.inbox_sequence, idempotency_key = fresh("ack")}, workspace)
            test.eq(ack.state, "acknowledged")
            local settlement: Outcome? = nil
            for _ = 1, 120 do
                settlement = observe_exit(pid)
                if settlement then break end
            end
            if not settlement or not settlement.value then error("the production carrier did not settle: " .. tostring(settlement and settlement.error)) end
            test.eq((settlement.value.settlement :: Object).outcome, "succeeded")
            local first_end, pushed = 0, 0
            for _, item in ipairs(records_of(target_thread, TARGET_ACTOR)) do
                if item.kind == "observation" and item.source == "stream" then
                    local data = (item.body :: Object).data :: Object
                    if data.type == "turn.signal" and data.phase == "ended" and first_end == 0 then first_end = item.sequence :: integer end
                    local value = json.encode(item.body)
                    if value:find("push:", 1, true) and value:find(tostring(sent.record_id), 1, true) then pushed = item.sequence :: integer end
                end
            end
            test.is_true(first_end > 0 and pushed > first_end, "production push was not observed after the initial turn")
        end)
        test.it("admits the push acceptance against the pinned Claude executable, or reports the gate open", function()
            local claude = claude_bin()
            if not claude then
                test.eq(launch.CLAUDE_AUTHENTICATION, "unproven")
                return
            end
            if not shell(claude .. " --version"):find("Claude Code", 1, true) then error("not the Claude executable") end
            prepare_production(claude)
            local label = fresh("push-pin-ws")
            local workspace = tostring(call("bee.workspace.catalog:create", {label = label, root_ref = ROOT,
                subpath = label, create_directory = true}).workspace_id)
            local thread_id = tostring(call_as(TARGET_ACTOR, "bee.threads.service:create", {thread_id = fresh("push-pin-thread"),
                idempotency_key = fresh("key"), title = "Pinned push"}, workspace).thread_id)
            local target = session(thread_id, workspace, {PATH = "/usr/bin:/bin"}, TARGET_ACTOR)
            local pid = spawn(target)
            local admitted = false
            local outcome: Outcome? = nil
            for _ = 1, 90 do
                outcome = observe_exit(pid)
                if outcome then break end
                if action_admitted(thread_id, tostring(target.action_id), TARGET_ACTOR) then admitted = true; break end
            end
            if outcome then
                -- Past the acceptance: only the environment or the provider
                -- account may stop the run, never push admission.
                if tostring(outcome.error):find("acceptance", 1, true) then error("the pinned executable was not admitted: " .. tostring(outcome.error)) end
                return
            end
            test.is_true(admitted, "the pinned executable run admitted no action")
            test.eq(launch.CLAUDE_AUTHENTICATION, "unproven")
            for _ = 1, 120 do
                outcome = observe_exit(pid)
                if outcome then break end
            end
        end)
    end)
end

return test.run_cases(define_tests)
