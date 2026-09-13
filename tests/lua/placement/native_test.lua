-- MIT. The native placement against the runtime it runs on: intent before
-- creation, fail-closed capability, a full runner flow with acknowledged
-- streams, stop escalation, uncertainty without identity, cleanup only
-- after a proven exit.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local process = require("process")
local channel = require("channel")
local time = require("time")
local registry = require("registry")
local exec = require("exec")
local service = require("service")
local configuration = require("configuration")
local configuration_protocol = require("configuration_protocol")
local hash = require("hash")
local json = require("json")
local store = require("store")
local protocol = require("protocol")
local homes = require("homes")
local quote = require("quote")
local types = require("types")
local OWNER = "bee.test.owner"
local DIGEST = string.rep("b", 64)
local ROOT = "bee.placement.native:project_fixture"
local POLICY = "bee.placement.native:test_launch_policy"
local NO_PROVIDER_POLICY = "bee.placement.native:test_launch_policy_without_provider"
local FIXTURE_BINDING = "bee.placement.native:fixture_agent_binding"
local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end
local function caller(actor: string)
    local policies: {security.Policy} = {}
    for index, name in ipairs({"bee.placement.native:client_test_policy", "bee:resource_manage_policy", "bee:resource_grant_policy", "bee:credential_manage_policy", "bee:credential_issue_policy"}) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    return funcs.new():with_actor(security.new_actor(actor)):with_scope(security.new_scope(policies))
end
local SENTINEL = "placement-sentinel-4e5f6a"
local function credential_call(method: string, value: unknown): {[string]: unknown}
    local reply, err = caller(OWNER):call("bee.credentials:" .. method, value)
    if err then error(method .. ": " .. tostring(err)) end
    local typed = reply :: service.Reply
    if not typed.ok then error(method .. ": " .. tostring(typed.error and typed.error.code) .. ": " .. tostring(typed.error and typed.error.message)) end
    return typed.value :: {[string]: unknown}
end
local function admit_credential_source()
    local entry = registry.get("bee:credential_sources")
    if not entry then error("credential sources entry") end
    local data = entry.data :: {[string]: unknown}
    local list = data.sources :: {{[string]: unknown}}
    for _, item in ipairs(list) do
        if item.ref == "bee.placement.native:sentinel_key" then return end
    end
    list[#list + 1] = {ref = "bee.placement.native:sentinel_key", workspace_id = "*", audience = OWNER, provider = "claude", projection_kinds = {"environment"}}
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("admit credential source: " .. tostring(err)) end
end
local function admit_login_source(source: string)
    local entry = registry.get("bee:credential_sources")
    if not entry then error("credential sources entry") end
    local data = entry.data :: {[string]: unknown}
    local list = data.sources :: {{[string]: unknown}}
    list[#list + 1] = {ref = source, workspace_id = "*", audience = OWNER, provider = "codex", projection_kinds = {"file"}}
    local file_policy = registry.get("bee:credential_file_policy")
    if not file_policy then error("credential file policy entry") end
    file_policy.data.policy.resources = {source}
    local changes = registry.snapshot():changes()
    changes:update(entry)
    changes:update(file_policy)
    local applied, apply_error = changes:apply()
    if not applied then error("admit login source: " .. tostring(apply_error)) end
end
local function resource_mode(mode: string)
    local entry = registry.get("bee.placement.native:resource_mode")
    if not entry then error("resource mode entry") end
    local data = entry.data :: {[string]: unknown}
    data.mode = mode
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("set resource mode: " .. tostring(err)) end
end
local function resource_call(method: string, value: unknown): {[string]: unknown}
    local reply, err = caller(OWNER):call("bee.resources:" .. method, value)
    if err then error(method .. ": " .. tostring(err)) end
    local typed = reply :: service.Reply
    if not typed.ok then error(method .. ": " .. tostring(typed.error and typed.error.code) .. ": " .. tostring(typed.error and typed.error.message)) end
    return typed.value :: {[string]: unknown}
end
local function call(actor: string, method: string, value: unknown): service.Reply
    local reply, err = caller(actor):call("bee.placement.native:" .. method, value)
    if err then error(method .. ": " .. tostring(err)) end
    return reply :: service.Reply
end
local function value(reply: service.Reply): {[string]: unknown}
    if not reply.ok then error(tostring(reply.error and reply.error.code) .. ": " .. tostring(reply.error and reply.error.message)) end
    return reply.value :: {[string]: unknown}
end
local function attempt_of(reply: service.Reply): types.Attempt
    return value(reply) :: types.Attempt
end
local function await(future: funcs.Future): service.Reply
    local _, open = future:response():receive()
    if not open then error("prepare race closed without a reply") end
    local payload, result_error = future:result()
    if result_error then error("prepare race: " .. tostring(result_error)) end
    if not payload then error("prepare race returned no reply") end
    local data = payload:data()
    if type(data) ~= "table" then error("prepare race reply returned " .. type(data)) end
    return data :: service.Reply
end
local function launch(command: {string}, required: string): {[string]: unknown}
    local argv: {string} = {}
    for index = 2, #command do argv[index - 1] = command[index] end
    return {idempotency_key = fresh("key"), owner_id = OWNER, owner_incarnation = 1, action_id = fresh("action"), attempt_id = fresh("attempt"),
        binding_ref = FIXTURE_BINDING, policy_ref = NO_PROVIDER_POLICY, profile_id = "batch", binding_digest = DIGEST, profile_digest = DIGEST,
        launch = {executable = command[1], argv = argv, environment = {"PROBE_VALUE"}, working_directory_ref = "project", readiness = "none"},
        resources = {{name = "project", grant_ref = "grant-1", root_ref = ROOT, subpath = "", access = "write", purpose = "project"}},
        environment = {PROBE_VALUE = "probe-42"}, required_cleanup = required, required_exit_observation = "eof_gated", timeouts = {start_ms = 10000, stop_grace_ms = 500}}
end
local function provider_configuration(): {[string]: unknown}
    local provider = registry.get("bee.placement.native:codex_test_provider")
    if not provider then error("provider entry") end
    local decoded, decode_error = configuration.decode("bee.placement.native:codex_test_provider", provider)
    if not decoded then error(tostring(decode_error)) end
    local rendered, render_error = configuration.projection(decoded)
    if not rendered then error(tostring(render_error)) end
    -- The provider projection includes its own diagnostic fields; the native
    -- launch boundary accepts only the materialized configuration contract.
    return {revision = rendered.revision, path = rendered.path, content = rendered.content,
        digest = rendered.digest, provider_ref = rendered.provider_ref}
end
local function provider_configuration_digest(): string
    local provider = registry.get("bee.placement.native:codex_test_provider")
    if not provider then error("provider entry") end
    local digest, digest_error = configuration_protocol.digest({provider_ref = "bee.placement.native:codex_test_provider", provider = provider, fixture = true}, "bee.driver.codex:configure")
    if not digest then error(tostring(digest_error)) end
    return digest
end
local function retained_launch(owner: string, session_ref: string, marker: string): {[string]: unknown}
    local request = launch({"sh", "-c", "printf '" .. marker .. "\\n' >> \"$HOME/marker\""}, "direct_process")
    request.owner_id = owner
    request.session_ref = session_ref
    request.policy_ref = POLICY
    request.binding_ref = "bee.driver.codex:binding"
    local declared = request.launch :: {[string]: unknown}
    declared.home_ref = "session"
    local resources = request.resources :: {{[string]: unknown}}
    resources[#resources + 1] = {name = "session", grant_ref = "session-grant", root_ref = ROOT, subpath = "", access = "write", purpose = "session"}
    request.configuration_digest = provider_configuration_digest()
    return request
end
local READONLY = "bee.placement.native:readonly_fixture"
local function admit_root(ref: string)
    local entry = registry.get(ref)
    if not entry then error("admitted roots entry") end
    local data = entry.data :: {[string]: unknown}
    local roots = data.roots :: {{[string]: unknown}}
    for _, root in ipairs(roots) do
        if root.root_ref == ROOT then return end
    end
    roots[#roots + 1] = {root_ref = ROOT, access = "write"}
    roots[#roots + 1] = {root_ref = READONLY, access = "read"}
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("admit root: " .. tostring(err)) end
end
local function activate_fixture_binding()
    local entry = registry.get("bee:harness_activation")
    if not entry then error("harness activation") end
    local data = entry.data :: {[string]: unknown}
    local bindings = data.bindings :: {unknown}
    for _, binding in ipairs(bindings) do if binding == FIXTURE_BINDING then return end end
    bindings[#bindings + 1] = FIXTURE_BINDING
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("activate fixture binding: " .. tostring(err)) end
end
local function wait_for(predicate: () -> boolean, timeout_ms: integer): boolean
    local deadline = time.now():unix_nano() + timeout_ms * 1000000
    while time.now():unix_nano() < deadline do
        if predicate() then return true end
        time.sleep("50ms")
    end
    return predicate()
end
local function kinds(attempt_id: string): {string}
    local page = value(call(OWNER, "evidence", {attempt_id = attempt_id, limit = 64}))
    local list: {string} = {}
    for _, item in ipairs(page.evidence :: {{[string]: unknown}}) do list[#list + 1] = tostring(item.kind) end
    return list
end
local function alive(pid: string): boolean
    local executor = assert(exec.get("bee.placement.native:executor"))
    local proc = assert(executor:exec("sh -c 'kill -0 " .. pid .. " 2>/dev/null && echo alive || echo gone'"))
    local stdout = proc:stdout_stream()
    assert(proc:start())
    local output = tostring(stdout:read(64) or "")
    proc:wait()
    stdout:close()
    executor:release()
    return output:find("alive", 1, true) ~= nil
end
local function shell(command: string): string
    local executor = assert(exec.get("bee.placement.native:executor"))
    local proc = assert(executor:exec(quote.line({"sh", "-c", command})))
    local stdout = proc:stdout_stream()
    assert(proc:start())
    local output = ""
    while true do
        local chunk: unknown = stdout:read(4096)
        if type(chunk) ~= "string" or chunk == "" then break end
        output = output .. (chunk :: string)
    end
    proc:wait()
    stdout:close()
    executor:release()
    return output
end
local function has(list: {string}, wanted: string): boolean
    for _, item in ipairs(list) do
        if item == wanted then return true end
    end
    return false
end
local function define_tests()
    test.describe("Native placement", function()
        resource_mode("host_configured")
        admit_root("bee.placement.native:admitted_roots")
        admit_root("bee:resource_roots")
        activate_fixture_binding()
        local measured = value(service.capabilities())
        local capability = tostring(measured.capability)
        local observation = tostring(measured.exit_observation)
        test.it("refuses native and gateway environment collisions before intent", function()
            for _, kind in ipairs({"home", "home_ref", "gateway", "hook", "shared_token", "gateway_home"}) do
                local request = launch({"sh", "-c", "true"}, "direct_process")
                local environment = request.environment :: {[string]: string}
                if kind == "home" then
                    environment.HOME = "/unselected/home"
                elseif kind == "home_ref" then
                    request.environment_refs = {HOME = "fixture:home"}
                else
                    local gateway: {[string]: unknown} = {endpoint = "127.0.0.1:4312", tools = {"thread_read"}, hooks = {}, destination = "BEE_GATEWAY_TOKEN"}
                    if kind == "gateway" then environment.BEE_GATEWAY_TOKEN = "caller-token" end
                    if kind == "hook" then
                        gateway.hooks = {"SessionStart"}
                        gateway.hook_destination = "BEE_HOOK_TOKEN"
                        request.environment_refs = {BEE_HOOK_TOKEN = "fixture:token"}
                    end
                    if kind == "shared_token" then gateway.hooks = {"SessionStart"}; gateway.hook_destination = "BEE_GATEWAY_TOKEN" end
                    if kind == "gateway_home" then gateway.destination = "HOME" end
                    request.gateway = gateway
                end
                local refused = call(OWNER, "prepare", request)
                test.is_false(refused.ok)
                test.eq(refused.error and refused.error.code, "INVALID")
                local detail = refused.error and refused.error.message or ""
                test.is_true(detail:find("owned", 1, true) ~= nil or detail:find("already assigned", 1, true) ~= nil)
                local absent = call(OWNER, "status", {attempt_id = request.attempt_id})
                test.eq(absent.error and absent.error.code, "NOT_FOUND")
            end
        end)
        test.it("records intent only for admitted, cleanable launches and replays by key", function()
            local request = launch({"sh", "-c", "true"}, "direct_process")
            local first = attempt_of(call(OWNER, "prepare", request))
            test.eq(first.execution_state, "intended")
            test.eq(first.cleanup_state, "pending")
            test.eq(first.capability, capability)
            test.eq(first.evidence_count, 1)
            local again = attempt_of(call(OWNER, "prepare", request))
            test.eq(again.attempt_id, first.attempt_id)
            local other = launch({"sh", "-c", "true"}, "direct_process")
            other.idempotency_key = request.idempotency_key
            local conflict = call(OWNER, "prepare", other)
            test.is_false(conflict.ok)
            test.eq(conflict.error and conflict.error.code, "CONFLICT")
            local foreign = launch({"sh", "-c", "true"}, "direct_process")
            local denied = call("bee.test.other", "prepare", foreign)
            test.eq(denied.error and denied.error.code, "FORBIDDEN")
            local elsewhere = launch({"sh", "-c", "true"}, "direct_process")
            local grant = (elsewhere.resources :: {{[string]: unknown}})[1]
            grant.root_ref = "bee.placement.native:root"
            local refused = call(OWNER, "prepare", elsewhere)
            test.eq(refused.error and refused.error.code, "FORBIDDEN")
            local narrow = launch({"sh", "-c", "true"}, "direct_process")
            local narrow_grant = (narrow.resources :: {{[string]: unknown}})[1]
            narrow_grant.root_ref = READONLY
            -- The launch line cannot allow a gateway tool the binding does not admit.
            local allowing = launch({"claude", "-p", "hi", "--allowedTools", "Read,mcp__bee__thread_post"}, "direct_process")
            local wider = call(OWNER, "prepare", allowing)
            test.eq(wider.error and wider.error.code, "DENIED")
            local bare = call(OWNER, "prepare", launch({"claude", "-p", "hi", "--allowed-tools=mcp__bee"}, "direct_process"))
            test.eq(bare.error and bare.error.code, "DENIED")
            local widened = call(OWNER, "prepare", narrow)
            test.eq(widened.error and widened.error.code, "FORBIDDEN")
            narrow_grant.access = "read"
            local narrowed = attempt_of(call(OWNER, "prepare", narrow))
            test.eq(narrowed.execution_state, "intended")
            test.eq(measured.resource_authority, "host_configured")
            test.is_false(measured.delegated_resource_grants == true)
            test.is_true(measured.credential_broker == true)
            if observation == "eof_gated" then
                local managed = launch({"sh", "-c", "true"}, "direct_process")
                managed.required_exit_observation = "independent"
                local gated = call(OWNER, "prepare", managed)
                test.eq(gated.error and gated.error.code, "UNSUPPORTED_CAPABILITY")
            end
            local strongest = launch({"sh", "-c", "true"}, "contained_tree")
            local closed = call(OWNER, "prepare", strongest)
            test.eq(closed.error and closed.error.code, "UNSUPPORTED_CAPABILITY")
            local db = store.open()
            if not db then error("store") end
            test.is_nil(store.by_key(db, OWNER, strongest.idempotency_key :: string))
            db:release()
            if capability == "direct_process" then
                local grouped = call(OWNER, "prepare", launch({"sh", "-c", "true"}, "process_group"))
                test.eq(grouped.error and grouped.error.code, "UNSUPPORTED_CAPABILITY")
            end
        end)
        test.it("runs a child through the runner with acknowledged streams and a proven exit", function()
            local request = launch({"sh", "-c", "echo start:$PROBE_VALUE; pwd; read line; echo got:$line; echo warn 1>&2"}, "direct_process")
            local prepared = attempt_of(call(OWNER, "prepare", request))
            local outputs = assert(process.listen(protocol.TOPIC_OUTPUT, {message = true}))
            local acks = assert(process.listen(protocol.TOPIC_ACK, {message = true}))
            local exits = assert(process.listen(protocol.TOPIC_EXIT, {message = true}))
            local stale = call(OWNER, "attach", {attempt_id = prepared.attempt_id, recipient = process.pid(), generation = 0})
            test.eq(stale.error and stale.error.code, "INVALID")
            local attached = attempt_of(call(OWNER, "attach", {attempt_id = prepared.attempt_id, recipient = process.pid(), generation = 1}))
            test.eq(attached.attachment_generation, 1)
            local replaced = call(OWNER, "attach", {attempt_id = prepared.attempt_id, recipient = process.pid(), generation = 1})
            test.eq(replaced.error and replaced.error.code, "CONFLICT")
            local started = attempt_of(call(OWNER, "start", {attempt_id = prepared.attempt_id}))
            test.eq(started.execution_state, "running")
            test.not_nil(started.home_ref)
            test.eq(attempt_of(call(OWNER, "start", {attempt_id = prepared.attempt_id})).execution_state, "running")
            local text = ""
            local highest = 0
            local function collect(until_text: string): boolean
                local deadline = time.after("10s")
                while not text:find(until_text, 1, true) do
                    local selected = channel.select({outputs:case_receive(), deadline:case_receive()})
                    if not selected.ok or selected.channel == deadline then return false end
                    local data = selected.value:payload():data() :: {[string]: unknown}
                    test.eq(data.attempt_id, prepared.attempt_id)
                    test.eq(data.generation, 1)
                    if data.data then text = text .. tostring(data.data) end
                    local sequence = math.floor(data.sequence :: number)
                    if sequence <= highest then error("sequence " .. tostring(sequence) .. " after " .. tostring(highest)) end
                    highest = sequence
                    process.send(tostring(selected.value:from()), protocol.TOPIC_ACK, {generation = 1, consumed_through = sequence})
                end
                return true
            end
            if not collect("start:probe-42") then error("no start output; received: " .. text) end
            if not text:find("placement%-project") then error("pwd is not the project root; received: " .. text) end
            local runner = ""
            do
                local db = store.open()
                if not db then error("store") end
                local row = store.row(db, prepared.attempt_id)
                db:release()
                runner = tostring(row and row.runner_pid)
            end
            process.send(runner, protocol.TOPIC_INPUT, {write_id = "w-1", generation = 1, data = "ping\n"})
            local ack = acks:receive()
            local accepted = ack:payload():data() :: {[string]: unknown}
            test.eq(accepted.write_id, "w-1")
            if accepted.accepted ~= true then error("write refused: " .. tostring(accepted.reason)) end
            process.send(runner, protocol.TOPIC_INPUT, {write_id = "w-1", generation = 1, data = "ping\n"})
            local repeated = acks:receive():payload():data() :: {[string]: unknown}
            if repeated.accepted ~= true then error("repeated write refused: " .. tostring(repeated.reason)) end
            if not collect("got:ping") then error("no echo of the input; received: " .. text) end
            local exit = exits:receive():payload():data() :: {[string]: unknown}
            test.eq(exit.code, 0)
            if exit.uncertain == true then error("exit reported uncertain") end
            if not collect("warn") then error("no stderr; received: " .. text) end
            if not wait_for(function()
                return (value(call(OWNER, "status", {attempt_id = prepared.attempt_id})).attempt :: types.Attempt).execution_state == "exited"
            end, 5000) then error("exit not recorded: " .. tostring((value(call(OWNER, "status", {attempt_id = prepared.attempt_id})).attempt :: types.Attempt).execution_state)) end
            local status = value(call(OWNER, "status", {attempt_id = prepared.attempt_id}))
            local attempt = status.attempt :: types.Attempt
            test.eq(attempt.execution_state, "exited")
            test.eq((attempt.exit :: types.Exit).code, 0)
            local liveness = status.liveness :: types.Liveness
            if capability == "process_group" then
                if not liveness.observed or liveness.alive == true then error("exited child still reads alive: " .. liveness.detail) end
            else
                test.is_false(liveness.observed)
            end
            local recorded = kinds(prepared.attempt_id)
            for _, expected in ipairs({"intent.recorded", "attach", "runner.started", "home.created", "child.started", "child.exited"}) do
                test.is_true(has(recorded, expected))
            end
            test.eq(attempt.cleanup_state, "pending")
            test.eq(attempt.exit_source, "runner")
            test.eq(attempt.exit_observation, observation)
            local cleaned = attempt_of(call(OWNER, "cleanup", {attempt_id = prepared.attempt_id}))
            test.eq(cleaned.cleanup_state, "complete")
            test.eq(cleaned.execution_state, "exited")
            local key = homes.attempt_key(OWNER, prepared.attempt_id)
            if homes.attempt_exists(key :: string) then error("attempt home remains after cleanup: " .. table.concat(kinds(prepared.attempt_id), ",")) end
            process.unlisten(outputs)
            process.unlisten(acks)
            process.unlisten(exits)
        end)
        test.it("escalates a cooperative stop and refuses cleanup before the exit is proven", function()
            local request = launch({"sh", "-c", "trap '' TERM; echo ready; sleep 8"}, "direct_process")
            local prepared = attempt_of(call(OWNER, "prepare", request))
            local early = call(OWNER, "cleanup", {attempt_id = prepared.attempt_id})
            test.eq(early.error and early.error.code, "CONFLICT")
            local started = attempt_of(call(OWNER, "start", {attempt_id = prepared.attempt_id}))
            test.eq(started.execution_state, "running")
            local blocked = call(OWNER, "cleanup", {attempt_id = prepared.attempt_id})
            test.eq(blocked.error and blocked.error.code, "CONFLICT")
            local stopping = attempt_of(call(OWNER, "stop", {attempt_id = prepared.attempt_id, mode = "cooperative"}))
            test.eq(stopping.execution_state, "stopping")
            if not wait_for(function()
                return (value(call(OWNER, "status", {attempt_id = prepared.attempt_id})).attempt :: types.Attempt).execution_state == "exited"
            end, 8000) then error("escalation did not end the child: " .. table.concat(kinds(prepared.attempt_id), ",")) end
            test.eq(attempt_of(call(OWNER, "reconcile", {attempt_id = prepared.attempt_id})).execution_state, "exited")
            local recorded = kinds(prepared.attempt_id)
            for _, wanted in ipairs({"stop.requested", "signal.term", "signal.kill", "child.exited"}) do
                if not has(recorded, wanted) then error("evidence lacks " .. wanted .. ": " .. table.concat(recorded, ",")) end
            end
            local cleaned = attempt_of(call(OWNER, "cleanup", {attempt_id = prepared.attempt_id}))
            test.eq(cleaned.cleanup_state, "complete")
        end)
        test.it("measures an executable read-only and refuses a start whose executable no longer measures as planned", function()
            local cwd = shell("pwd"):gsub("%s+$", "")
            local script = cwd .. "/.wippy/measured-" .. fresh("script") .. ".sh"
            shell('printf "#!/bin/sh\\necho measured\\n" > ' .. script .. " && chmod +x " .. script)
            local measured = value(call(OWNER, "measure_executable", {path = script}))
            test.eq(measured.revision, "bee.executable-measurement@1")
            test.eq(measured.kind, "script")
            test.eq(measured.interpreter, "/bin/sh")
            test.eq(tostring(measured.digest):len(), 64)
            test.eq(measured.digest, hash.sha256("#!/bin/sh\necho measured\n"))
            local image = value(call(OWNER, "measure_executable", {path = "/bin/sh"}))
            test.eq(image.kind, "elf")
            test.eq(tostring(image.digest):len(), 64)
            local reported = value(service.capabilities()).executable_measurement :: {[string]: unknown}
            test.eq(type(reported.streaming), "boolean")
            test.eq(type(reported.read_only_volume), "boolean")
            test.is_true(#tostring(reported.detail) > 0)
            if reported.read_only_volume == true then test.is_true(tostring(reported.detail):find("refused as read-only", 1, true) ~= nil) end
            test.eq(shell("ls " .. cwd .. "/.wippy/placement 2>/dev/null | grep -c measurement-probe || true"):match("%d+"), "0")
            local missing = call(OWNER, "measure_executable", {path = cwd .. "/.wippy/absent-" .. fresh("x")})
            test.eq(missing.error and missing.error.code, "UNAVAILABLE")
            local relative = call(OWNER, "measure_executable", {path = "bin/sh"})
            test.eq(relative.error and relative.error.code, "UNAVAILABLE")
            local request = launch({script}, "direct_process")
            request.executable = {revision = "bee.executable-measurement@1", kind = "script", digest = string.rep("0", 64)}
            local stale = attempt_of(call(OWNER, "prepare", request))
            local refused = call(OWNER, "start", {attempt_id = stale.attempt_id})
            test.is_false(refused.ok)
            test.is_true(has(kinds(stale.attempt_id), "executable.changed"))
            local fresh_request = launch({script}, "direct_process")
            fresh_request.executable = {revision = "bee.executable-measurement@1", kind = "script", digest = measured.digest :: string}
            local prepared = attempt_of(call(OWNER, "prepare", fresh_request))
            attempt_of(call(OWNER, "start", {attempt_id = prepared.attempt_id}))
            test.is_true(wait_for(function()
                return (value(call(OWNER, "status", {attempt_id = prepared.attempt_id})).attempt :: types.Attempt).execution_state == "exited"
            end, 8000))
            test.is_true(has(kinds(prepared.attempt_id), "executable.measured"))
            shell("rm -f " .. script)
        end)
        test.it("closes a live child's stdin at the owner's request and records it, or answers why it cannot", function()
            -- The shell reads stdin itself, so no descendant outlives a kill
            -- holding the pipes on a runtime without process groups.
            local request = launch({"sh", "-c", "while IFS= read -r line; do :; done; echo closed"}, "direct_process")
            local prepared = attempt_of(call(OWNER, "prepare", request))
            local outputs = assert(process.listen(protocol.TOPIC_OUTPUT, {message = true}))
            call(OWNER, "attach", {attempt_id = prepared.attempt_id, recipient = process.pid(), generation = 1})
            attempt_of(call(OWNER, "start", {attempt_id = prepared.attempt_id}))
            local unknown = call(OWNER, "close_stdin", {attempt_id = fresh("attempt")})
            test.is_false(unknown.ok)
            local closed = value(call(OWNER, "close_stdin", {attempt_id = prepared.attempt_id}))
            local supported = value(service.capabilities()).stdin_close == true
            local recorded = kinds(prepared.attempt_id)
            if supported then
                test.eq(closed.closed, true)
                test.is_true(has(recorded, "stdin.closed"))
                local text = ""
                local deadline = time.after("10s")
                while not text:find("closed", 1, true) do
                    local selected = channel.select({outputs:case_receive(), deadline:case_receive()})
                    if not selected.ok or selected.channel == deadline then error("the child did not see end of input; output: " .. text) end
                    local data = selected.value:payload():data() :: {[string]: unknown}
                    if data.data then text = text .. tostring(data.data) end
                    process.send(tostring(selected.value:from()), protocol.TOPIC_ACK, {generation = 1, consumed_through = math.floor(data.sequence :: number)})
                end
                if not wait_for(function()
                    return (value(call(OWNER, "status", {attempt_id = prepared.attempt_id})).attempt :: types.Attempt).execution_state == "exited"
                end, 8000) then error("the child did not exit after end of input") end
                local again = call(OWNER, "close_stdin", {attempt_id = prepared.attempt_id})
                test.eq(again.error and again.error.code, "CONFLICT")
            else
                test.eq(closed.closed, false)
                test.eq(closed.reason, "executor cannot close stdin")
                test.is_true(has(recorded, "stdin.uncertain"))
                attempt_of(call(OWNER, "stop", {attempt_id = prepared.attempt_id, mode = "forced"}))
            end
            process.unlisten(outputs)
        end)
        test.it("refuses a stale host configuration digest and retries only the matching plan", function()
            local provider = registry.get("bee.placement.native:codex_test_provider")
            if not provider then error("provider entry") end
            local rendered = assert(configuration.projection(assert(configuration.decode("bee.placement.native:codex_test_provider", provider))))
            local request = launch({"sh", "-c", "true"}, "direct_process")
            request.policy_ref = POLICY
            request.binding_ref = "bee.driver.codex:binding"
            request.configuration_digest = string.rep("0", 64)
            local refused = call(OWNER, "prepare", request)
            test.eq(refused.error and refused.error.code, "CONFLICT")
            test.is_true(tostring(refused.error and refused.error.message):find("inputs changed", 1, true) ~= nil)
            test.eq(call(OWNER, "status", {attempt_id = request.attempt_id}).error and call(OWNER, "status", {attempt_id = request.attempt_id}).error.code, "NOT_FOUND")
            request.configuration_digest = provider_configuration_digest()
            -- A digest from another host selection is a plan conflict, even
            -- where the replacement policy has no provider of its own.
            request.policy_ref = NO_PROVIDER_POLICY
            request.binding_ref = "bee.driver.claude:binding"
            local unselected = call(OWNER, "prepare", request)
            test.eq(unselected.error and unselected.error.code, "CONFLICT")
            test.is_true(tostring(unselected.error and unselected.error.message):find("inputs changed", 1, true) ~= nil)
            request.policy_ref = "bee.placement.native:codex_test_provider"
            local foreign = call(OWNER, "prepare", request)
            test.eq(foreign.error and foreign.error.code, "DENIED")
            test.is_true(tostring(foreign.error and foreign.error.message):find("not a host launch policy", 1, true) ~= nil)
            request.policy_ref = POLICY
            request.binding_ref = "bee.driver.codex:binding"
            local prepared = attempt_of(call(OWNER, "prepare", request))
            test.eq(prepared.execution_state, "intended")
            local db, open_error = store.open()
            if not db then error(open_error or "store") end
            local row, row_error = store.row(db, prepared.attempt_id)
            if not row then db:release(); error(row_error or "stored request") end
            local frozen, frozen_error = store.request(row)
            db:release()
            if not frozen then error(frozen_error or "frozen request") end
            test.eq(#(frozen.delivery and frozen.delivery.files or {}), 1)
            test.eq((frozen.delivery and frozen.delivery.files[1].digest), rendered.digest)
            -- A matching idempotency retry returns the existing intent and
            -- does not replace the owner-recorded driver delivery.
            test.eq(attempt_of(call(OWNER, "prepare", request)).attempt_id, prepared.attempt_id)
            local replay_db, replay_open_error = store.open()
            if not replay_db then error(replay_open_error or "store") end
            local replay_row, replay_row_error = store.row(replay_db, prepared.attempt_id)
            if not replay_row then replay_db:release(); error(replay_row_error or "replayed stored request") end
            local replayed, replay_error = store.request(replay_row)
            replay_db:release()
            if not replayed then error(replay_error or "replayed frozen request") end
            test.eq(replayed.delivery and replayed.delivery.files[1].digest, rendered.digest)
            test.eq(replayed.delivery and replayed.delivery.files[1].content, rendered.content)
            local started = attempt_of(call(OWNER, "start", {attempt_id = prepared.attempt_id}))
            test.eq(started.execution_state, "running")
            time.sleep("500ms")
            local recorded = kinds(prepared.attempt_id)
            test.is_true(has(recorded, "configuration.materialized"))
            local page = value(call(OWNER, "evidence", {attempt_id = prepared.attempt_id, limit = 64}))
            for _, item in ipairs(page.evidence :: {{[string]: unknown}}) do
                if item.kind == "configuration.materialized" then
                    test.is_true(tostring(item.detail):find("digest " .. rendered.digest, 1, true) ~= nil)
                    test.is_nil(tostring(item.detail):find("/home", 1, true))
                end
            end
        end)
        test.it("rejects malformed persisted delivery before creating a home or starting a child", function()
            local request = launch({"sh", "-c", "true"}, "direct_process")
            request.policy_ref = POLICY
            request.binding_ref = "bee.driver.codex:binding"
            request.configuration_digest = provider_configuration_digest()
            local prepared = attempt_of(call(OWNER, "prepare", request))
            local db, open_error = store.open()
            if not db then error(open_error or "store") end
            local row, row_error = store.row(db, prepared.attempt_id)
            if not row then db:release(); error(row_error or "stored request") end
            local original = row.request_json :: string
            local decoded = assert(json.decode(original)) :: {[string]: unknown}
            local delivery = decoded.delivery :: {[string]: unknown}
            local file = (delivery.files :: {{[string]: unknown}})[1]
            local corruptions: {{[string]: unknown}} = {
                {arguments = {"bad\0argument"}, files = {}},
                {arguments = {}, files = {file, file}},
                {arguments = {}, files = {{revision = file.revision, path = "../escape", content = file.content, digest = file.digest, provider_ref = file.provider_ref}}},
                {arguments = {}, files = {{revision = file.revision, path = file.path, content = "changed", digest = file.digest, provider_ref = file.provider_ref}}},
                {arguments = {}, files = {}, unsupported = true},
            }
            local home_key = assert(homes.attempt_key(OWNER, prepared.attempt_id))
            for index, damaged in ipairs(corruptions) do
                decoded.delivery = damaged
                local encoded = assert(json.encode(decoded))
                local _, write_error = db:execute("UPDATE bee_placement_attempts SET request_json = ? WHERE attempt_id = ?", {encoded, prepared.attempt_id})
                if write_error then db:release(); error("corrupt fixture row: " .. tostring(write_error)) end
                local damaged_row = assert(store.row(db, prepared.attempt_id))
                local persisted, persisted_error = store.request(damaged_row)
                test.is_nil(persisted, "persisted delivery corruption " .. tostring(index) .. " was accepted")
                test.not_nil(persisted_error)
                local refused = call(OWNER, "start", {attempt_id = prepared.attempt_id})
                test.eq(refused.error and refused.error.code, "STORAGE")
                test.is_false(homes.attempt_exists(home_key))
                test.eq(#kinds(prepared.attempt_id), 1)
            end
            local _, restore_error = db:execute("UPDATE bee_placement_attempts SET request_json = ? WHERE attempt_id = ?", {original, prepared.attempt_id})
            if restore_error then db:release(); error("restore fixture request: " .. tostring(restore_error)) end
            local restored_row = assert(store.row(db, prepared.attempt_id))
            local restored, restored_error = store.request(restored_row)
            db:release()
            if not restored then error(restored_error or "restored request") end
            test.eq(restored.delivery and restored.delivery.files[1].digest, file.digest)
        end)
        test.it("refuses a missing configuration when the host policy selects a provider before recording intent", function()
            local request = launch({"sh", "-c", "true"}, "direct_process")
            request.policy_ref = POLICY
            request.binding_ref = "bee.driver.codex:binding"
            local refused = call(OWNER, "prepare", request)

            local db, open_error = store.open()
            if not db then error(open_error or "store") end
            local attempt, read_error = store.attempt(db, request.attempt_id :: string)
            db:release()
            if read_error then error(read_error) end
            test.is_nil(attempt)
            test.is_false(refused.ok)
            test.eq(refused.error and refused.error.code, "DENIED")
            test.is_true(tostring(refused.error and refused.error.message):find("selected configuration digest", 1, true) ~= nil)
        end)
        test.it("refuses caller forged delivery before recording intent", function()
            local request = launch({"sh", "-c", "true"}, "direct_process")
            request.delivery = {arguments = {}, files = {}}
            local refused = call(OWNER, "prepare", request)
            test.is_false(refused.ok)
            test.eq(refused.error and refused.error.code, "INVALID")
            test.is_true(tostring(refused.error and refused.error.message):find("delivery", 1, true) ~= nil)
            local absent = call(OWNER, "status", {attempt_id = request.attempt_id})
            test.eq(absent.error and absent.error.code, "NOT_FOUND")
        end)
        test.it("atomically admits one competing retained-session intent", function()
            local session_ref = fresh("contended-session")
            local first = retained_launch(OWNER, session_ref, "contender-one")
            local second = retained_launch(OWNER, session_ref, "contender-two")
            local a, a_error = caller(OWNER):async("bee.placement.native:prepare", first)
            local b, b_error = caller(OWNER):async("bee.placement.native:prepare", second)
            if a_error or not a or b_error or not b then error("start prepare race: " .. tostring(a_error or b_error)) end
            local first_reply, second_reply = await(a), await(b)
            local replies = {first_reply, second_reply}
            local admitted = 0
            local refused = 0
            for _, reply in ipairs(replies) do
                if reply.ok then
                    admitted = admitted + 1
                else
                    test.eq(reply.error and reply.error.code, "CONFLICT")
                    refused = refused + 1
                end
            end
            test.eq(admitted, 1)
            test.eq(refused, 1)
            local rejected = first_reply.ok and second or first
            local db, open_error = store.open()
            if not db then error(open_error or "open store") end
            local absent, read_error = store.attempt(db, rejected.attempt_id :: string)
            db:release()
            if read_error then error(read_error) end
            test.is_nil(absent)

            -- An overlapping retry is not a second holder: both replies name
            -- the one recorded intent, with no additional receipt.
            local replay = retained_launch(OWNER, fresh("replay-session"), "same-request")
            local first_retry, first_retry_error = caller(OWNER):async("bee.placement.native:prepare", replay)
            local second_retry, second_retry_error = caller(OWNER):async("bee.placement.native:prepare", replay)
            if first_retry_error or not first_retry or second_retry_error or not second_retry then error("start replay race: " .. tostring(first_retry_error or second_retry_error)) end
            local replay_a, replay_b = attempt_of(await(first_retry)), attempt_of(await(second_retry))
            test.eq(replay_a.attempt_id, replay.attempt_id)
            test.eq(replay_b.attempt_id, replay.attempt_id)
            local receipt = kinds(replay.attempt_id :: string)
            test.eq(#receipt, 1)
            test.eq(receipt[1], "intent.recorded")
        end)
        test.it("retains a selected session home across attempts without adopting changed configuration", function()
            local session_ref = fresh("session")
            local first = retained_launch(OWNER, session_ref, "first")
            local first_prepared = attempt_of(call(OWNER, "prepare", first))
            -- The same admitted request is a replay, including while it is
            -- the retained home's only holder.
            test.eq(attempt_of(call(OWNER, "prepare", first)).attempt_id, first_prepared.attempt_id)
            local competing = retained_launch(OWNER, session_ref, "competing")
            local blocked = call(OWNER, "prepare", competing)
            test.eq(blocked.error and blocked.error.code, "CONFLICT")
            test.is_true(tostring(blocked.error and blocked.error.message):find("retained session is still held", 1, true) ~= nil)
            test.eq(attempt_of(call(OWNER, "start", {attempt_id = first_prepared.attempt_id})).execution_state, "running")
            test.is_true(wait_for(function()
                return (value(call(OWNER, "status", {attempt_id = first_prepared.attempt_id})).attempt :: types.Attempt).execution_state == "exited"
            end, 8000))
            -- Exit alone is not release: cleanup has to prove its scope.
            local exited_holder = call(OWNER, "prepare", retained_launch(OWNER, session_ref, "exited-holder"))
            test.eq(exited_holder.error and exited_holder.error.code, "CONFLICT")
            attempt_of(call(OWNER, "cleanup", {attempt_id = first_prepared.attempt_id}))
            local second = retained_launch(OWNER, session_ref, "second")
            local second_prepared = attempt_of(call(OWNER, "prepare", second))
            test.eq(attempt_of(call(OWNER, "start", {attempt_id = second_prepared.attempt_id})).execution_state, "running")
            test.is_true(wait_for(function()
                return (value(call(OWNER, "status", {attempt_id = second_prepared.attempt_id})).attempt :: types.Attempt).execution_state == "exited"
            end, 8000))
            local key, key_error = homes.session_key(OWNER, session_ref)
            if not key then error(tostring(key_error)) end
            local session_path, session_error = homes.ensure_session(key)
            if not session_path then error(tostring(session_error)) end
            local home_path, home_error = homes.os_path(session_path .. "/home")
            if not home_path then error(tostring(home_error)) end
            test.eq(shell("cat " .. home_path .. "/marker"), "first\nsecond\n")
            local expected = provider_configuration()
            local sum = shell("sha256sum " .. home_path .. "/.codex/config.toml"):match("^([0-9a-f]+)")
            test.eq(sum, expected.digest)
            local second_evidence = kinds(second_prepared.attempt_id)
            test.is_true(has(second_evidence, "configuration.materialized"))
            local first_home, first_home_error = homes.attempt_key(OWNER, first_prepared.attempt_id)
            if not first_home then error(tostring(first_home_error)) end
            local second_home, second_home_error = homes.attempt_key(OWNER, second_prepared.attempt_id)
            if not second_home then error(tostring(second_home_error)) end
            attempt_of(call(OWNER, "cleanup", {attempt_id = second_prepared.attempt_id}))
            test.is_false(homes.attempt_exists(first_home))
            test.is_false(homes.attempt_exists(second_home))
            test.eq(shell("cat " .. home_path .. "/marker"), "first\nsecond\n")

            local other_owner = "bee.test.session_other"
            local other = retained_launch(other_owner, session_ref, "other")
            local other_prepared = attempt_of(call(other_owner, "prepare", other))
            test.eq(attempt_of(call(other_owner, "start", {attempt_id = other_prepared.attempt_id})).execution_state, "running")
            test.is_true(wait_for(function()
                return (value(call(other_owner, "status", {attempt_id = other_prepared.attempt_id})).attempt :: types.Attempt).execution_state == "exited"
            end, 8000))
            local other_key, other_key_error = homes.session_key(other_owner, session_ref)
            if not other_key then error(tostring(other_key_error)) end
            test.neq(other_key, key)
            local other_path, other_path_error = homes.ensure_session(other_key)
            if not other_path then error(tostring(other_path_error)) end
            local other_home, other_home_error = homes.os_path(other_path .. "/home")
            if not other_home then error(tostring(other_home_error)) end
            test.eq(shell("cat " .. other_home .. "/marker"), "other\n")

            local direct_key, direct_key_error = homes.session_key(OWNER, fresh("session"))
            if not direct_key then error(tostring(direct_key_error)) end
            local direct_path, direct_path_error = homes.ensure_session(direct_key)
            if not direct_path then error(tostring(direct_path_error)) end
            local created: {[string]: boolean} = {}
            local written, write_error = homes.write_protected(direct_path, ".codex/config.toml", "approved", created, true)
            if not written then error(tostring(write_error)) end
            local replayed, replay_error, replay = homes.write_protected(direct_path, ".codex/config.toml", "approved", {}, true)
            if not replayed then error(tostring(replay_error)) end
            test.eq(replay, true)
            local changed, changed_error = homes.write_protected(direct_path, ".codex/config.toml", "changed", {}, true)
            test.is_nil(changed)
            test.eq(changed_error, "retained configuration differs from host-approved content")
            local unowned_key, unowned_key_error = homes.session_key(OWNER, fresh("session"))
            if not unowned_key then error(tostring(unowned_key_error)) end
            local unowned_path, unowned_path_error = homes.ensure_session(unowned_key)
            if not unowned_path then error(tostring(unowned_path_error)) end
            local made_parent, made_parent_error = homes.write_protected(unowned_path, ".codex/other.toml", "approved", {}, true)
            if not made_parent then error(tostring(made_parent_error)) end
            local adopted, adopted_error = homes.write_protected(unowned_path, ".codex/config.toml", "approved", {}, true)
            test.is_nil(adopted)
            test.eq(adopted_error, "configuration parent already exists")
            local missing = launch({"sh", "-c", "true"}, "direct_process")
            missing.session_ref = fresh("session")
            local missing_launch = missing.launch :: {[string]: unknown}
            missing_launch.home_ref = "session"
            local denied = call(OWNER, "prepare", missing)
            test.eq(denied.error and denied.error.code, "INVALID")
            test.eq(denied.error and denied.error.message, "launch.home_ref names no resource")
        end)
        test.it("creates nested configuration parents without adopting existing ancestors", function()
            local key, key_error = homes.session_key(OWNER, fresh("nested-config"))
            if not key then error(tostring(key_error)) end
            local path, path_error = homes.ensure_session(key)
            if not path then error(tostring(path_error)) end
            local created: {[string]: boolean} = {}
            local written, write_error = homes.write_protected(path, ".gemini/config/mcp_config.json", "approved", created, true)
            test.not_nil(written)
            test.is_nil(write_error)
            local sibling, sibling_error = homes.write_protected(path, ".gemini/GEMINI.md", "instructions", created, true)
            test.not_nil(sibling)
            test.is_nil(sibling_error)
            local replayed, replay_error, replay = homes.write_protected(path, ".gemini/config/mcp_config.json", "approved", {}, true)
            test.not_nil(replayed)
            test.is_nil(replay_error)
            test.is_true(replay == true)
            local refused, refused_error = homes.write_protected(path, ".gemini/new/config.json", "unapproved", {}, true)
            test.is_nil(refused)
            test.eq(refused_error, "configuration parent already exists")
        end)
        test.it("seeds fixed private login destinations and preserves harness-refreshed bytes", function()
            local session_key = assert(homes.session_key(OWNER, fresh("login-session")))
            local session_path = assert(homes.ensure_session(session_key))
            local source = {provider = "codex", definition_id = "bee.test.codex_login", definition_revision = 1}
            local seeded, seed_error, resumed = homes.retain_login(session_path, source, "initial-login-bytes")
            test.not_nil(seeded)
            test.is_nil(seed_error)
            test.is_false(resumed == true)
            local home = assert(homes.os_path(session_path .. "/home"))
            -- A provider owns the opaque bytes once seeded. This stands in for
            -- a harness refresh between retained launches.
            test.eq(shell("printf refreshed-login-bytes > " .. home .. "/.codex/auth.json"), "")
            local replayed, replay_error, replay = homes.retain_login(session_path, source, "stale-broker-bytes")
            test.not_nil(replayed)
            test.is_nil(replay_error)
            test.is_true(replay == true)
            test.eq(shell("cat " .. home .. "/.codex/auth.json"), "refreshed-login-bytes")
            local claude_key = assert(homes.session_key(OWNER, fresh("claude-login-session")))
            local claude_session = assert(homes.ensure_session(claude_key))
            local claude = assert(homes.retain_login(claude_session,
                {provider = "claude", definition_id = "bee.test.claude_login", definition_revision = 1}, "claude-login-bytes"))
            test.is_true(claude:find("/.claude/.credentials.json", 1, true) ~= nil)
            local claude_home, home_error = homes.os_path(claude_session .. "/home")
            if not claude_home then error(tostring(home_error)) end
            test.eq(shell("cat " .. quote.posix(claude_home .. "/.claude.json")), '{"hasCompletedOnboarding":true}')
            test.eq(shell("printf private-settings > " .. quote.posix(claude_home .. "/.claude.json")), "")
            local _, replay_error = homes.retain_login(claude_session,
                {provider = "claude", definition_id = "bee.test.claude_login", definition_revision = 1}, "stale-login")
            test.is_nil(replay_error)
            test.eq(shell("cat " .. quote.posix(claude_home .. "/.claude.json")), "private-settings")
        end)
        test.it("leaves Claude onboarding to the harness when no machine login is available", function()
            local key, key_error = homes.session_key(OWNER, fresh("claude-no-login"))
            if not key then error(tostring(key_error)) end
            local session_path, session_error = homes.ensure_session(key)
            if not session_path then error(tostring(session_error)) end
            local target, seed_error = homes.retain_login(session_path,
                {provider = "claude", definition_id = "bee.test.claude_login", definition_revision = 1, optional = true}, nil)
            test.not_nil(target)
            test.is_nil(seed_error)
            local home, home_error = homes.os_path(session_path .. "/home")
            if not home then error(tostring(home_error)) end
            test.eq(shell("test ! -e " .. quote.posix(home .. "/.claude.json") .. " && printf absent"), "absent")
        end)
        test.it("retains optional login absence and preserves later private sign-in and sign-out", function()
            local session_key = assert(homes.session_key(OWNER, fresh("optional-login")))
            local session_path = assert(homes.ensure_session(session_key))
            local source = {provider = "codex", definition_id = "bee.test.optional_login", definition_revision = 1, optional = true}
            local created: {[string]: boolean} = {}
            local target, seed_error = homes.retain_login(session_path, source, nil, created)
            test.not_nil(target)
            test.is_nil(seed_error)
            local home = assert(homes.os_path(session_path .. "/home"))
            test.eq(shell("test ! -e " .. home .. "/.codex/auth.json && printf absent"), "absent")
            -- The immutable driver config can follow the intentionally empty login.
            test.not_nil(homes.write_protected(session_path, ".codex/config.toml", "approved", created, true))
            test.eq(shell("printf private-sign-in > " .. home .. "/.codex/auth.json"), "")
            local _, replay_error, replayed = homes.retain_login(session_path, source, "machine-login")
            test.is_nil(replay_error)
            test.is_true(replayed == true)
            test.eq(shell("cat " .. home .. "/.codex/auth.json"), "private-sign-in")
            test.eq(shell("rm " .. home .. "/.codex/auth.json"), "")
            local _, logout_error = homes.retain_login(session_path, source, "machine-login")
            test.is_nil(logout_error)
            test.eq(shell("test ! -e " .. home .. "/.codex/auth.json && printf absent"), "absent")
            local _, changed_error = homes.retain_login(session_path,
                {provider = "codex", definition_id = "bee.test.optional_login", definition_revision = 1}, "machine-login")
            test.eq(changed_error, "retained login source changed")
            local _, empty_error = homes.retain_login(session_path, source, "")
            test.eq(empty_error, "login bytes exceed bound")
            local _, required_error = homes.retain_login(session_path,
                {provider = "codex", definition_id = "bee.test.required_login", definition_revision = 1}, nil)
            test.eq(required_error, "required login bytes missing")
        end)
        test.it("refuses changed or incomplete retained login state without exposing bytes", function()
            local session_key = assert(homes.session_key(OWNER, fresh("login-reject-session")))
            local session_path = assert(homes.ensure_session(session_key))
            local source = {provider = "codex", definition_id = "bee.test.login_source", definition_revision = 1}
            assert(homes.retain_login(session_path, source, "opaque-login-not-in-errors"))
            for _, changed in ipairs({
                {provider = "claude", definition_id = "bee.test.login_source", definition_revision = 1},
                {provider = "codex", definition_id = "bee.test.other_login_source", definition_revision = 1},
                {provider = "codex", definition_id = "bee.test.login_source", definition_revision = 2},
            }) do
                local _, changed_error = homes.retain_login(session_path, changed, "different-opaque-login-bytes")
                test.eq(changed_error, "retained login source changed")
                test.is_nil(changed_error:find("opaque-login-not-in-errors", 1, true))
                test.is_nil(changed_error:find("different-opaque-login-bytes", 1, true))
            end
            local partial_key = assert(homes.session_key(OWNER, fresh("login-partial-session")))
            local partial_session = assert(homes.ensure_session(partial_key))
            local made, made_error = homes.write_protected(partial_session, ".codex/auth.json", "partial", {[(partial_session .. "/home/.codex")] = true}, true)
            test.not_nil(made)
            test.is_nil(made_error)
            local _, partial_error = homes.retain_login(partial_session, source, "opaque-login-not-in-errors")
            test.eq(partial_error, "retained login is incomplete")
            -- This inspects the live root; the assertion is not inferred from
            -- the fs.directory manifest's requested mode.
            local root = assert(homes.os_path("/"))
            test.eq(shell("stat -c %a " .. root):match("%d+"), "700")
        end)
        test.it("keeps a retained home excluded when its placement is uncertain", function()
            local session_ref = fresh("uncertain-session")
            local first = attempt_of(call(OWNER, "prepare", retained_launch(OWNER, session_ref, "uncertain")))
            local db, open_error = store.open()
            if not db then error(open_error or "open store") end
            local uncertain = store.transition(db, first.attempt_id, {execution = "uncertain",
                evidence = {kind = "test.uncertain", detail = "placement outcome is not proven"}})
            db:release()
            test.eq(uncertain.ok, true)
            local blocked = call(OWNER, "prepare", retained_launch(OWNER, session_ref, "must-not-run"))
            test.eq(blocked.error and blocked.error.code, "CONFLICT")
            test.is_true(tostring(blocked.error and blocked.error.message):find("retained session is still held", 1, true) ~= nil)
        end)
        test.it("drains for a bounded time after an independently observed exit while descendants hold the pipes", function()
            local request = launch({"sh", "-c", "sleep 2 & echo hi"}, "direct_process")
            request.timeouts = {start_ms = 10000, stop_grace_ms = 500, drain_ms = 300, retain_ms = 300}
            local prepared = attempt_of(call(OWNER, "prepare", request))
            local started = attempt_of(call(OWNER, "start", {attempt_id = prepared.attempt_id}))
            time.sleep("1200ms")
            local recorded = kinds(prepared.attempt_id)
            if started.exit_observation == "independent" then
                test.is_true(has(recorded, "child.exited"))
                test.is_true(has(recorded, "output.drain_elapsed"))
            else
                test.is_false(has(recorded, "output.drain_elapsed"))
                time.sleep("1500ms")
                test.is_true(has(kinds(prepared.attempt_id), "child.exited"))
            end
        end)
        test.it("records unacknowledged output as lost once the retention deadline passes after exit", function()
            local request = launch({"sh", "-c", "echo one; echo two"}, "direct_process")
            request.timeouts = {start_ms = 10000, stop_grace_ms = 500, retain_ms = 300}
            local prepared = attempt_of(call(OWNER, "prepare", request))
            attempt_of(call(OWNER, "attach", {attempt_id = prepared.attempt_id, recipient = process.pid(), generation = 1}))
            attempt_of(call(OWNER, "start", {attempt_id = prepared.attempt_id}))
            time.sleep("1500ms")
            local recorded = kinds(prepared.attempt_id)
            test.is_true(has(recorded, "child.exited"))
            test.is_true(has(recorded, "output.lost"))
            test.is_true(has(recorded, "runner.finished"))
            local page = value(call(OWNER, "evidence", {attempt_id = prepared.attempt_id, limit = 64}))
            for _, item in ipairs(page.evidence :: {{[string]: unknown}}) do
                if item.kind == "output.lost" then test.is_true(tostring(item.detail):find("unacknowledged chunks", 1, true) ~= nil) end
            end
        end)
        test.it("keeps supervising a live attempt without an execution identity while its runner answers", function()
            local request = launch({"sh", "-c", "sleep 8"}, "direct_process")
            local prepared = attempt_of(call(OWNER, "prepare", request))
            local started = attempt_of(call(OWNER, "start", {attempt_id = prepared.attempt_id}))
            test.eq(started.execution_state, "running")
            local db = store.open()
            if not db then error("store") end
            local _, clear_error = db:execute("UPDATE bee_placement_attempts SET pid = NULL, pgid = NULL, start_ticks = NULL, boot_id = NULL WHERE attempt_id = ?", {prepared.attempt_id})
            db:release()
            if clear_error then error("clear identity: " .. tostring(clear_error)) end
            local reconciled = attempt_of(call(OWNER, "reconcile", {attempt_id = prepared.attempt_id}))
            test.eq(reconciled.execution_state, "running")
            test.is_true(has(kinds(prepared.attempt_id), "reconcile.supervised"))
            local page = value(call(OWNER, "evidence", {attempt_id = prepared.attempt_id, limit = 64}))
            local reported = false
            for _, item in ipairs(page.evidence :: {{[string]: unknown}}) do
                if item.kind == "reconcile.supervised" and tostring(item.detail):find("runner reports running", 1, true) then reported = true end
            end
            test.is_true(reported)
            test.eq(attempt_of(call(OWNER, "reconcile", {attempt_id = prepared.attempt_id})).execution_state, "running")
            call(OWNER, "stop", {attempt_id = prepared.attempt_id, mode = "forced"})
        end)
        test.it("keeps uncertainty when the runner is lost without an execution identity", function()
            local request = launch({"sh", "-c", "sleep 8"}, "direct_process")
            local prepared = attempt_of(call(OWNER, "prepare", request))
            local db = store.open()
            if not db then error("store") end
            -- Inject the persisted state left by an unobserved execution.
            -- Starting and killing a real child first allowed the background
            -- sweep to prove its exit before the fixture removed its identity.
            local _, clear_error = db:execute("UPDATE bee_placement_attempts SET execution_state = 'running', runner_pid = NULL, pid = NULL, pgid = NULL, start_ticks = NULL, boot_id = NULL WHERE attempt_id = ?", {prepared.attempt_id})
            db:release()
            if clear_error then error("clear identity: " .. tostring(clear_error)) end
            local reconciled = attempt_of(call(OWNER, "reconcile", {attempt_id = prepared.attempt_id}))
            test.eq(reconciled.execution_state, "uncertain")
            local stopped = attempt_of(call(OWNER, "stop", {attempt_id = prepared.attempt_id, mode = "forced"}))
            test.eq(stopped.execution_state, "uncertain")
            local blocked = call(OWNER, "cleanup", {attempt_id = prepared.attempt_id})
            test.eq(blocked.error and blocked.error.code, "CONFLICT")
        end)
        test.it("resolves grants through the resource authority when the host selects granted mode", function()
            local workspace = fresh("ws")
            resource_call("associate", {workspace_id = workspace, name = "project", root_ref = ROOT, subpath = "", allowed_access = "write"})
            resource_mode("granted")
            local attempt_id = fresh("attempt")
            local granted = resource_call("grant", {workspace_id = workspace, name = "project", access = "write", purpose = "project", audience = OWNER, attempt_id = attempt_id})
            local request = launch({"sh", "-c", "pwd"}, "direct_process")
            request.attempt_id = attempt_id
            local grant = (request.resources :: {{[string]: unknown}})[1]
            grant.grant_ref = granted.grant_id
            grant.root_ref = "bee.placement.native:root"
            local prepared = attempt_of(call(OWNER, "prepare", request))
            test.eq(prepared.execution_state, "intended")
            local reported = value(service.capabilities())
            test.eq(reported.resource_authority, "granted")
            test.is_true(reported.delegated_resource_grants == true)
            local downgraded = launch({"sh", "-c", "true"}, "direct_process")
            local plain = (downgraded.resources :: {{[string]: unknown}})[1]
            plain.grant_ref = "host"
            local refused = call(OWNER, "prepare", downgraded)
            test.eq(refused.error and refused.error.code, "NOT_FOUND")
            local foreign = launch({"sh", "-c", "true"}, "direct_process")
            local borrowed = (foreign.resources :: {{[string]: unknown}})[1]
            borrowed.grant_ref = granted.grant_id
            local scoped = call(OWNER, "prepare", foreign)
            test.eq(scoped.error and scoped.error.code, "DENIED")
            local short_attempt = fresh("attempt")
            local short = resource_call("grant", {workspace_id = workspace, name = "project", access = "read", purpose = "project", audience = OWNER, attempt_id = short_attempt, ttl_ms = 300})
            local expiring = launch({"sh", "-c", "true"}, "direct_process")
            expiring.attempt_id = short_attempt
            local expiring_grant = (expiring.resources :: {{[string]: unknown}})[1]
            expiring_grant.grant_ref = short.grant_id
            expiring_grant.access = "read"
            attempt_of(call(OWNER, "prepare", expiring))
            time.sleep("400ms")
            local late = call(OWNER, "start", {attempt_id = short_attempt})
            test.eq(late.error and late.error.code, "EXPIRED")
            test.is_true(has(kinds(short_attempt), "grant.refused"))
            local started = attempt_of(call(OWNER, "start", {attempt_id = attempt_id}))
            test.eq(started.execution_state, "running")
            resource_mode("host_configured")
        end)
        test.it("stops a running attempt whose grant is revoked, with enforcement pending until the exit is proven", function()
            local workspace = fresh("ws")
            resource_call("associate", {workspace_id = workspace, name = "project", root_ref = ROOT, subpath = "", allowed_access = "write"})
            resource_mode("granted")
            local attempt_id = fresh("attempt")
            local granted = resource_call("grant", {workspace_id = workspace, name = "project", access = "write", purpose = "project", audience = OWNER, attempt_id = attempt_id})
            local request = launch({"sh", "-c", "sleep 8"}, "direct_process")
            request.attempt_id = attempt_id
            local grant = (request.resources :: {{[string]: unknown}})[1]
            grant.grant_ref = granted.grant_id
            attempt_of(call(OWNER, "prepare", request))
            test.eq(attempt_of(call(OWNER, "start", {attempt_id = attempt_id})).execution_state, "running")
            local before = attempt_of(call(OWNER, "reconcile", {attempt_id = attempt_id}))
            test.is_true(before.execution_state == "running" or before.execution_state == "uncertain")
            resource_call("revoke", {grant_id = granted.grant_id})
            local db = store.open()
            if not db then error("store") end
            local _, identify_error = db:execute("UPDATE bee_placement_attempts SET pid = COALESCE(pid, 0) WHERE attempt_id = ?", {attempt_id})
            db:release()
            if identify_error then error("identify: " .. tostring(identify_error)) end
            local enforced = call(OWNER, "reconcile", {attempt_id = attempt_id})
            local recorded = kinds(attempt_id)
            if capability == "process_group" then
                test.is_true(enforced.ok)
                test.is_true(has(recorded, "grant.revoked"))
                test.is_true(has(recorded, "stop.requested"))
                if not wait_for(function()
                    return (value(call(OWNER, "status", {attempt_id = attempt_id})).attempt :: types.Attempt).execution_state == "exited"
                end, 8000) then error("revocation did not end the child: " .. table.concat(kinds(attempt_id), ",")) end
            else
                attempt_of(call(OWNER, "stop", {attempt_id = attempt_id, mode = "forced"}))
            end
            resource_mode("host_configured")
        end)
        test.it("refuses file credentials before intent without a selected retained home", function()
            local source = "bee.credentials:codex_login_fixture"
            admit_login_source(source)
            local workspace = fresh("ws")
            credential_call("define", {workspace_id = workspace, name = "login", provider = "codex", source = {kind = "fs_directory", ref = source}})
            local attempt_id = fresh("attempt")
            local projection = credential_call("issue_projection", {workspace_id = workspace, name = "login", audience = OWNER, attempt_id = attempt_id, profile_id = "batch",
                profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = fresh("key")})
            local request = launch({"sh", "-c", "exit 0"}, "direct_process")
            request.attempt_id = attempt_id
            request.projections = {projection.projection_id}
            local refused = call(OWNER, "prepare", request)
            test.is_false(refused.ok)
            test.eq(refused.error.code, "DENIED")
            local absent = call(OWNER, "status", {attempt_id = attempt_id})
            test.is_false(absent.ok)
            test.eq(absent.error.code, "NOT_FOUND")
        end)
        test.it("starts with an absent optional machine login and permits private CLI sign-in", function()
            local source = "bee.credentials:codex_login_fixture"
            admit_login_source(source)
            test.eq(shell("mkdir -p .wippy/codex-login-fixture && rm -f .wippy/codex-login-fixture/auth.json"), "")
            local workspace = fresh("optional-login-workspace")
            credential_call("define", {workspace_id = workspace, name = "login", provider = "codex",
                source = {kind = "fs_directory", ref = source}, optional = true})
            local session_ref = fresh("optional-login-session")
            local request = retained_launch(OWNER, session_ref, "optional-login")
            local attempt_id = request.attempt_id :: string
            local projection = credential_call("issue_projection", {workspace_id = workspace, name = "login", audience = OWNER,
                attempt_id = attempt_id, profile_id = "batch", profile_digest = DIGEST, binding_digest = DIGEST,
                launch_policy_digest = DIGEST, idempotency_key = fresh("optional-login-key")})
            request.projections = {projection.projection_id}
            local launch_value = request.launch :: {[string]: unknown}
            launch_value.argv = {"-c", 'test ! -e "$HOME/.codex/auth.json" && printf private-login > "$HOME/.codex/auth.json"'}
            attempt_of(call(OWNER, "prepare", request))
            attempt_of(call(OWNER, "start", {attempt_id = attempt_id}))
            if not wait_for(function()
                return (value(call(OWNER, "status", {attempt_id = attempt_id})).attempt :: types.Attempt).execution_state == "exited"
            end, 8000) then error("optional login probe did not exit") end
            local exited = (value(call(OWNER, "status", {attempt_id = attempt_id})).attempt :: types.Attempt).exit
            if not exited then error("optional login probe has no exit receipt") end
            test.eq(exited.code, 0)
            local session_key = assert(homes.session_key(OWNER, session_ref))
            local session_path = assert(homes.ensure_session(session_key))
            local home = assert(homes.os_path(session_path .. "/home"))
            test.eq(shell("cat " .. home .. "/.codex/auth.json"), "private-login")
            attempt_of(call(OWNER, "cleanup", {attempt_id = attempt_id}))
        end)
        test.it("delivers one retained Codex login before provider configuration and preserves a refreshed login", function()
            local source = "bee.credentials:codex_login_fixture"
            admit_login_source(source)
            test.eq(shell("mkdir -p .wippy/codex-login-fixture && printf '{\"fixture\":\"login\"}' > .wippy/codex-login-fixture/auth.json"), "")
            local workspace = fresh("login-workspace")
            credential_call("define", {workspace_id = workspace, name = "login", provider = "codex", source = {kind = "fs_directory", ref = source}})
            local session_ref = fresh("login-session")
            local function issue(attempt_id: string): {[string]: unknown}
                return credential_call("issue_projection", {workspace_id = workspace, name = "login", audience = OWNER, attempt_id = attempt_id, profile_id = "batch",
                    profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = fresh("login-key")})
            end
            local first_request = retained_launch(OWNER, session_ref, "first-login")
            local first_id = first_request.attempt_id :: string
            local first_launch = first_request.launch :: {[string]: unknown}
            -- Execute env directly. A shell can remove invalid names such as
            -- auth.json before its env builtin observes them.
            first_launch.executable = "/usr/bin/env"
            first_launch.argv = {}
            first_request.projections = {issue(first_id).projection_id}
            attempt_of(call(OWNER, "prepare", first_request))
            local outputs = assert(process.listen(protocol.TOPIC_OUTPUT, {message = true}))
            attempt_of(call(OWNER, "attach", {attempt_id = first_id, recipient = process.pid(), generation = 1}))
            local started = attempt_of(call(OWNER, "start", {attempt_id = first_id}))
            local child_environment = ""
            local ended: {[string]: boolean} = {}
            local deadline = time.after("10s")
            while not ended.stdout or not ended.stderr do
                local selected = channel.select({outputs:case_receive(), deadline:case_receive()})
                if not selected.ok or selected.channel == deadline then
                    process.unlisten(outputs)
                    error("did not receive the complete raw child environment")
                end
                local data = selected.value:payload():data() :: protocol.Output
                if tostring(selected.value:from()) == started.runner and data.attempt_id == first_id and data.generation == 1 then
                    test.is_false(data.truncated == true)
                    if data.data then child_environment = child_environment .. tostring(data.data) end
                    if data.eof then ended[data.stream] = true end
                    process.send(tostring(selected.value:from()), protocol.TOPIC_ACK, {generation = 1, consumed_through = data.sequence})
                end
            end
            process.unlisten(outputs)
            if not wait_for(function()
                return (value(call(OWNER, "status", {attempt_id = first_id})).attempt :: types.Attempt).execution_state == "exited"
            end, 8000) then error("first retained login launch did not exit") end
            local first_exit = (value(call(OWNER, "status", {attempt_id = first_id})).attempt :: types.Attempt).exit
            if not first_exit then error("environment probe has no exit receipt") end
            test.eq(first_exit.code, 0)
            test.not_nil(child_environment:find("PROBE_VALUE=probe-42\n", 1, true))
            test.is_nil(child_environment:find('{"fixture":"login"}', 1, true))
            attempt_of(call(OWNER, "cleanup", {attempt_id = first_id}))
            local session_key = assert(homes.session_key(OWNER, session_ref))
            local session_path = assert(homes.ensure_session(session_key))
            local home = assert(homes.os_path(session_path .. "/home"))
            test.eq(shell("test -f " .. home .. "/.codex/auth.json && test -f " .. home .. "/.codex/config.toml"), "")
            test.eq(shell("printf '{\"fixture\":\"refreshed\"}' > " .. home .. "/.codex/auth.json"), "")
            local second_request = retained_launch(OWNER, session_ref, "second-login")
            local second_id = second_request.attempt_id :: string
            second_request.projections = {issue(second_id).projection_id}
            attempt_of(call(OWNER, "prepare", second_request))
            attempt_of(call(OWNER, "start", {attempt_id = second_id}))
            if not wait_for(function()
                return (value(call(OWNER, "status", {attempt_id = second_id})).attempt :: types.Attempt).execution_state == "exited"
            end, 8000) then error("second retained login launch did not exit") end
            test.eq(shell("cat " .. home .. "/.codex/auth.json"), '{"fixture":"refreshed"}')
            local page = value(call(OWNER, "evidence", {attempt_id = second_id, limit = 64}))
            for _, item in ipairs(page.evidence :: {{[string]: unknown}}) do
                test.is_nil(tostring(item.detail):find("refreshed", 1, true))
            end
            attempt_of(call(OWNER, "cleanup", {attempt_id = second_id}))
            local changed_request = retained_launch(OWNER, session_ref, "changed-login")
            local changed_id = changed_request.attempt_id :: string
            credential_call("define", {workspace_id = workspace, name = "login", provider = "codex", source = {kind = "fs_directory", ref = source}})
            changed_request.projections = {issue(changed_id).projection_id}
            attempt_of(call(OWNER, "prepare", changed_request))
            local refused = call(OWNER, "start", {attempt_id = changed_id})
            test.is_false(refused.ok)
            test.eq(refused.error and refused.error.code, "UNAVAILABLE")
            test.is_true(has(kinds(changed_id), "credential.refused"))
            test.is_nil(shell("cat " .. home .. "/marker"):find("changed-login", 1, true))
        end)
        test.it("materializes a credential projection into the child and keeps the secret out of evidence", function()
            admit_credential_source()
            local workspace = fresh("ws")
            credential_call("define", {workspace_id = workspace, name = "anthropic", provider = "claude", source = {kind = "env_variable", ref = "bee.placement.native:sentinel_key"}})
            local attempt_id = fresh("attempt")
            local projection = credential_call("issue_projection", {workspace_id = workspace, name = "anthropic", audience = OWNER, attempt_id = attempt_id, profile_id = "batch",
                profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = fresh("key")})
            local request = launch({"sh", "-c", "echo credential:${#ANTHROPIC_API_KEY}"}, "direct_process")
            request.attempt_id = attempt_id
            request.projections = {projection.projection_id}
            local prepared = attempt_of(call(OWNER, "prepare", request))
            test.eq(prepared.execution_state, "intended")
            local outputs = assert(process.listen(protocol.TOPIC_OUTPUT, {message = true}))
            attempt_of(call(OWNER, "attach", {attempt_id = attempt_id, recipient = process.pid(), generation = 1}))
            attempt_of(call(OWNER, "start", {attempt_id = attempt_id}))
            local text = ""
            local deadline = time.after("10s")
            while not text:find("credential:", 1, true) do
                local selected = channel.select({outputs:case_receive(), deadline:case_receive()})
                if not selected.ok or selected.channel == deadline then error("no output; received: " .. text) end
                local data = selected.value:payload():data() :: {[string]: unknown}
                if data.data then text = text .. tostring(data.data) end
                process.send(tostring(selected.value:from()), protocol.TOPIC_ACK, {generation = 1, consumed_through = math.floor(data.sequence :: number)})
            end
            process.unlisten(outputs)
            test.is_true(text:find("credential:" .. tostring(#SENTINEL), 1, true) ~= nil)
            local page = value(call(OWNER, "evidence", {attempt_id = attempt_id, limit = 64}))
            local kinds_seen: {string} = {}
            for _, item in ipairs(page.evidence :: {{[string]: unknown}}) do
                if tostring(item.detail):find(SENTINEL, 1, true) then error("sentinel leaked into evidence") end
                kinds_seen[#kinds_seen + 1] = tostring(item.kind)
            end
            test.is_true(has(kinds_seen, "credential.materialized"))
            local db = store.open()
            if not db then error("store") end
            local row = store.row(db, attempt_id)
            db:release()
            if tostring(row and row.request_json):find(SENTINEL, 1, true) then error("sentinel leaked into the stored request") end
            local other_attempt = fresh("attempt")
            local foreign = launch({"sh", "-c", "true"}, "direct_process")
            foreign.attempt_id = other_attempt
            foreign.projections = {projection.projection_id}
            local scoped = call(OWNER, "prepare", foreign)
            test.eq(scoped.error and scoped.error.code, "DENIED")
            local revoked_attempt = fresh("attempt")
            local revocable = credential_call("issue_projection", {workspace_id = workspace, name = "anthropic", audience = OWNER, attempt_id = revoked_attempt, profile_id = "batch",
                profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = fresh("key")})
            local sleeping = launch({"sh", "-c", "sleep 8"}, "direct_process")
            sleeping.attempt_id = revoked_attempt
            sleeping.projections = {revocable.projection_id}
            attempt_of(call(OWNER, "prepare", sleeping))
            test.eq(attempt_of(call(OWNER, "start", {attempt_id = revoked_attempt})).execution_state, "running")
            credential_call("revoke", {projection_id = revocable.projection_id})
            local swept = value(service.sweep())
            test.is_true((swept.reconciled :: number) >= 1)
            local recorded = kinds(revoked_attempt)
            if capability == "process_group" then
                test.is_true(has(recorded, "credential.revoked"))
                test.is_false(has(recorded, "grant.revoked"))
                test.is_true(has(recorded, "stop.requested"))
            else
                attempt_of(call(OWNER, "stop", {attempt_id = revoked_attempt, mode = "forced"}))
            end
            local reported = value(service.capabilities())
            local enforcement = reported.revocation_enforcement :: {[string]: unknown}
            test.eq(enforcement.mode, "stop_on_reconcile")
            test.eq(enforcement.scheduling_delay_ms, 30000)
            test.eq(enforcement.reconcile_timeout_ms, 5000)
            test.eq(enforcement.sweep_bound, 64)
            local missing_attempt = fresh("attempt")
            local missing = credential_call("issue_projection", {workspace_id = workspace, name = "anthropic", audience = OWNER, attempt_id = missing_attempt, profile_id = "batch",
                profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = fresh("key")})
            local unrunnable = launch({"/nonexistent/binary/for/bee", "--flag"}, "direct_process")
            unrunnable.attempt_id = missing_attempt
            unrunnable.projections = {missing.projection_id}
            attempt_of(call(OWNER, "prepare", unrunnable))
            local failed = call(OWNER, "start", {attempt_id = missing_attempt})
            test.is_false(failed.ok)
            if tostring(failed.error and failed.error.message):find(SENTINEL, 1, true) then error("sentinel leaked into the start reply") end
            local failed_page = value(call(OWNER, "evidence", {attempt_id = missing_attempt, limit = 64}))
            for _, item in ipairs(failed_page.evidence :: {{[string]: unknown}}) do
                if tostring(item.detail):find(SENTINEL, 1, true) then error("sentinel leaked into failure evidence") end
            end
            local sweeper = process.registry.lookup(service.SWEEPER_NAME)
            test.not_nil(sweeper)
        end)
        test.it("refuses colliding credential destinations without starting a child or leaking bytes", function()
            admit_credential_source()
            local workspace = fresh("credential-collision")
            for _, name in ipairs({"first", "second"}) do
                credential_call("define", {workspace_id = workspace, name = name, provider = "claude",
                    source = {kind = "env_variable", ref = "bee.placement.native:sentinel_key"}})
            end
            for _, duplicate_projection in ipairs({false, true}) do
                local request = launch({"sh", "-c", "echo child-must-not-run"}, "direct_process")
                local attempt_id = request.attempt_id :: string
                local projections: {string} = {}
                for _, name in ipairs(duplicate_projection and {"first", "second"} or {"first"}) do
                    local projection = credential_call("issue_projection", {workspace_id = workspace, name = name, audience = OWNER,
                        attempt_id = attempt_id, profile_id = "batch", profile_digest = DIGEST, binding_digest = DIGEST,
                        launch_policy_digest = DIGEST, idempotency_key = fresh("projection")})
                    projections[#projections + 1] = projection.projection_id :: string
                end
                request.projections = projections
                if not duplicate_projection then
                    (request.environment :: {[string]: string}).ANTHROPIC_API_KEY = "policy-value"
                end
                attempt_of(call(OWNER, "prepare", request))
                local failed = call(OWNER, "start", {attempt_id = attempt_id})
                test.is_false(failed.ok)
                local message = tostring(failed.error and failed.error.message)
                test.is_true(message:find("ANTHROPIC_API_KEY is already assigned", 1, true) ~= nil)
                test.is_nil(message:find(SENTINEL, 1, true))
                local page = value(call(OWNER, "evidence", {attempt_id = attempt_id, limit = 64}))
                local refused = false
                for _, item in ipairs(page.evidence :: {{[string]: unknown}}) do
                    test.is_true(item.kind ~= "child.started")
                    test.is_nil(tostring(item.detail):find(SENTINEL, 1, true))
                    if item.kind == "credential.refused" then refused = true end
                end
                test.is_true(refused)
                local db = store.open()
                if not db then error("placement store") end
                local row = store.row(db, attempt_id)
                db:release()
                test.is_nil(tostring(row and row.request_json):find(SENTINEL, 1, true))
            end
        end)
        test.it("sweeps live attempts in bounded batches that make progress and survives a sweeper restart", function()
            local ids: {string} = {}
            for index = 1, 3 do
                local request = launch({"sh", "-c", "sleep 8"}, "direct_process")
                ids[index] = request.attempt_id :: string
                attempt_of(call(OWNER, "prepare", request))
                test.eq(attempt_of(call(OWNER, "start", {attempt_id = ids[index]})).execution_state, "running")
            end
            -- Each sweep takes at most the bound; every live attempt is reached
            -- within a bounded number of sweeps, and an attempt a sweep settled
            -- as uncertain or exited is not swept again.
            local previous_bound = service.SWEEP_BOUND
            service.SWEEP_BOUND = 2
            local function touched_count(): integer
                local total = 0
                for _, id in ipairs(ids) do
                    local page = value(call(OWNER, "evidence", {attempt_id = id, limit = 64}))
                    for _, item in ipairs(page.evidence :: {{[string]: unknown}}) do
                        if tostring(item.kind):find("^reconcile%.") then
                            total = total + 1
                            break
                        end
                    end
                end
                return total
            end
            local sweeps = 0
            while touched_count() < 3 and sweeps < 3 do
                local swept = value(service.sweep())
                test.is_true((swept.reconciled :: number) <= 2)
                sweeps = sweeps + 1
            end
            service.SWEEP_BOUND = previous_bound
            test.eq(touched_count(), 3)
            test.is_true(sweeps >= 2)
            local before = process.registry.lookup(service.SWEEPER_NAME)
            if not before then error("sweeper is not registered") end
            assert(process.terminate(tostring(before)))
            local restarted = wait_for(function()
                local now = process.registry.lookup(service.SWEEPER_NAME)
                return now ~= nil and tostring(now) ~= tostring(before)
            end, 10000)
            test.is_true(restarted)
            for _, id in ipairs(ids) do attempt_of(call(OWNER, "stop", {attempt_id = id, mode = "forced"})) end
        end)
        if capability == "process_group" then
            test.it("proves absence from identity after the runner is lost", function()
                local request = launch({"sh", "-c", "sleep 8"}, "process_group")
                local prepared = attempt_of(call(OWNER, "prepare", request))
                attempt_of(call(OWNER, "start", {attempt_id = prepared.attempt_id}))
                local db = store.open()
                if not db then error("store") end
                local row = store.row(db, prepared.attempt_id)
                local runner = tostring(row and row.runner_pid)
                local _, clear_error = db:execute("UPDATE bee_placement_attempts SET runner_pid = NULL WHERE attempt_id = ?", {prepared.attempt_id})
                db:release()
                if clear_error then error("clear runner: " .. tostring(clear_error)) end
                local before = value(call(OWNER, "status", {attempt_id = prepared.attempt_id}))
                local live = before.liveness :: types.Liveness
                if not live.observed or live.alive ~= true then error("running child not identified alive: " .. live.detail) end
                test.eq(attempt_of(call(OWNER, "reconcile", {attempt_id = prepared.attempt_id})).execution_state, "running")
                process.terminate(runner)
                if not wait_for(function() return attempt_of(call(OWNER, "reconcile", {attempt_id = prepared.attempt_id})).execution_state == "exited" end, 5000) then
                    error("runner loss did not end the child: " .. table.concat(kinds(prepared.attempt_id), ","))
                end
                test.is_true(has(kinds(prepared.attempt_id), "reconcile.absent"))
                local absent = value(call(OWNER, "status", {attempt_id = prepared.attempt_id})).attempt :: types.Attempt
                test.eq(absent.exit_source, "reconcile")
                local cleaned = attempt_of(call(OWNER, "cleanup", {attempt_id = prepared.attempt_id}))
                test.eq(cleaned.cleanup_state, "complete")
                test.is_true(has(kinds(prepared.attempt_id), "cleanup.complete"))
            end)
            test.it("removes the grandchild with the group on stop", function()
                local request = launch({"sh", "-c", "sleep 8 & echo child:$!; wait"}, "process_group")
                local prepared = attempt_of(call(OWNER, "prepare", request))
                local outputs = assert(process.listen(protocol.TOPIC_OUTPUT, {message = true}))
                call(OWNER, "attach", {attempt_id = prepared.attempt_id, recipient = process.pid(), generation = 1})
                attempt_of(call(OWNER, "start", {attempt_id = prepared.attempt_id}))
                local grandchild = ""
                local deadline = time.after("10s")
                while grandchild == "" do
                    local selected = channel.select({outputs:case_receive(), deadline:case_receive()})
                    if not selected.ok or selected.channel == deadline then break end
                    local data = selected.value:payload():data() :: {[string]: unknown}
                    grandchild = tostring(data.data or ""):match("child:(%d+)") or ""
                end
                test.neq(grandchild, "")
                local stopped = call(OWNER, "stop", {attempt_id = prepared.attempt_id, mode = "forced"})
                if not stopped.ok then
                    local status = value(call(OWNER, "status", {attempt_id = prepared.attempt_id})).attempt :: types.Attempt
                    local page = value(call(OWNER, "evidence", {attempt_id = prepared.attempt_id, limit = 64}))
                    local lines: {string} = {}
                    for _, item in ipairs(page.evidence :: {{[string]: unknown}}) do lines[#lines + 1] = tostring(item.kind) .. ": " .. tostring(item.detail) end
                    error("stop refused: " .. tostring(stopped.error and stopped.error.message) .. "; execution " .. status.execution_state .. " exit " .. tostring(status.exit and status.exit.code) .. " exit_source " .. tostring(status.exit_source) .. " grandchild alive " .. tostring(alive(grandchild)) .. "; evidence: " .. table.concat(lines, " | "))
                end
                if not wait_for(function()
                    return (value(call(OWNER, "status", {attempt_id = prepared.attempt_id})).attempt :: types.Attempt).execution_state == "exited"
                end, 8000) then error("forced stop did not end the child") end
                test.eq(attempt_of(call(OWNER, "reconcile", {attempt_id = prepared.attempt_id})).execution_state, "exited")
                test.is_true(wait_for(function() return not alive(grandchild) end, 5000))
                -- The stop intent is on record before the runner's exit
                -- observation, however fast the runner sees the kill land.
                local order: {string} = {}
                for _, item in ipairs(value(call(OWNER, "evidence", {attempt_id = prepared.attempt_id, limit = 64})).evidence :: {{[string]: unknown}}) do
                    if item.kind == "stop.requested" or item.kind == "child.exited" then order[#order + 1] = tostring(item.kind) end
                end
                test.eq(table.concat(order, ","), "stop.requested,child.exited")
                local cleaned = attempt_of(call(OWNER, "cleanup", {attempt_id = prepared.attempt_id}))
                test.eq(cleaned.cleanup_state, "complete")
                process.unlisten(outputs)
            end)
        end
    end)
end
return test.run_cases(define_tests)
