-- SPDX-License-Identifier: MIT
local process = require("process")
local channel = require("channel")
local time = require("time")
local security = require("security")
local tty = require("tty")
local funcs = require("funcs")
local json = require("json")
local registry = require("registry")
local fs = require("fs")
local appearance = require("appearance")
local admission = require("admission")
local machine = require("machine")
local protocol = require("protocol")
local bounds = require("bounds")
local placement_store = require("placement_store")
local WORKSPACE = string.rep("a", 32)
local M = {}
type Object = {[string]: unknown}
type Channel = channel.Channel
type Message = process.Message
local function object(value: unknown): Object
    if type(value) ~= "table" then error("missing object") end
    return value :: Object
end
local function call(target: string, value: unknown): Object
    local raw, call_error = funcs.call(target, value)
    if call_error then error(target .. " did not answer") end
    local result = object(raw)
    if result.ok ~= true then
        local fault = type(result.error) == "table" and object(result.error) or result
        error(target .. ": " .. tostring(fault.code) .. ": " .. tostring(fault.message or result.error))
    end
    return result
end
local function plain(value: string): string return (value:gsub("\27%[[0-9;]*m", "")) end
local function save(name: string, value: string)
    local volume = assert(fs.get("bee.docker.proof:evidence"))
    assert(volume:writefile("/" .. name, value))
end
local function receive(replies: Channel<Message>, request_id: string, operation: string): Object
    local deadline = time.after("20s")
    while true do
        local selected = channel.select({replies:case_receive(), deadline:case_receive()})
        assert(selected.ok and selected.channel == replies, "broker reply timed out")
        local data = selected.value:payload():data()
        if type(data) == "table" and data.request_id == request_id and data.op == operation then return object(data) end
    end
    error("broker reply missing")
end
local function profile(provider: string, mode: string): (string, string, admission.Plan)
    local definition = "bee.driver." .. provider .. (mode == "window" and ":default_window" or ":research_batch")
    local id = provider .. "-docker-" .. mode
    call("bee.harness.profiles:call", {operation = "put", workspace_id = WORKSPACE, profile_id = id,
        expected_revision = 0, idempotency_key = id, profile = {schema_revision = "bee.agent-profile@2", name = id, definition_ref = definition, driver_binding_ref = "bee.driver." .. provider .. ":binding", placement = {kind = "docker", profile_ref = "bee.docker.proof:profile"}, provider = {}, bee = {mcp = {}}}})
    local plan, refused = admission.resolve(definition, mode == "window" and "window" or "batch", WORKSPACE, id, 1)
    assert(plan, tostring(refused and refused.error and refused.error.message))
    call("bee.harness.launch:setup", {workspace_id = WORKSPACE, definition_ref = definition,
        saved_profile_id = id, saved_profile_revision = 1, expected_plan_digest = plan.plan_digest})
    return definition, id, plan
end
local function window(provider: string, definition: string, profile_id: string, plan: admission.Plan)
    save("admission.json", assert(json.encode(assert(registry.get("bee.security:application_admission")).data)))
    local owner = tostring(process.pid())
    local catalogs = assert(process.listen("bee.app.catalog", {message = true}))
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local broker_policy = assert(security.policy("bee.security.desktop:broker_policy"))
    local boundary = assert(security.policy("bee.security:core_spawn_boundary"))
    local scope = security.new_scope({broker_policy, boundary})
    local events = assert(process.events())
    local broker = tostring(assert(process.with_context({["bee.workspace_owner"] = owner, ["bee.workspace_id"] = WORKSPACE})
        :with_scope(scope):spawn_monitored("bee.apps:broker", "bee:workers", owner, appearance.defaults(), {})))
    save("phase.txt", "broker spawned")
    local deadline = time.after("20s")
    local catalog = channel.select({catalogs:case_receive(), events:case_receive(), deadline:case_receive()})
    if catalog.channel == events then error("broker startup: " .. tostring(json.encode(catalog.value))) end
    assert(catalog.ok and catalog.channel == catalogs, "broker did not publish its catalog")
    assert(tostring(catalog.value:from()) == broker)
    save("phase.txt", "catalog received")
    local request = assert(json.encode({request_id = provider .. "-window", definition_ref = definition, brief = "",
        saved_profile_id = profile_id, saved_profile_revision = 1, expected_plan_digest = plan.plan_digest}))
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "open", op = "open", workspace_id = WORKSPACE,
        definition_id = "bee.harness.app:app", arguments = {request}}))
    local opened = receive(replies, "open", "open")
    save("phase.txt", "window opened")
    assert(opened.error_code == "", tostring(opened.error))
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "bind", op = "bind", workspace_id = WORKSPACE,
        id = opened.id, instance_id = opened.instance_id, recipient = owner}))
    local attached = receive(replies, "bind", "attached")
    assert(attached.error_code == "", tostring(attached.error))
    local view = assert(tty.attach(tostring(attached.mount)))
    assert(view:send({type = "resize", width = 140, height = 40}))
    local ok, failure = pcall(function()
        local ready = false
        local trust_sent = false
        local trust_selected = false
        local theme_sent = false
        for index = 1, 2400 do
            local frame = plain(table.concat(assert(view:snapshot()).rows, "\n"))
            if index % 40 == 0 then save(provider .. "-startup.txt", frame) end
            if frame:find("Preparing Docker image", 1, true) then save("image-progress.txt", frame) end
            if not trust_sent and frame:lower():find("trust", 1, true) and (frame:find("folder", 1, true) or frame:find("directory", 1, true)) then
                if provider == "claude" and frame:match("❯%s+No,%s+exit") then
                    if not trust_selected then
                        save("trust-down.txt", frame)
                        assert(view:send({type = "key", key = "down", key_type = "down", action = "press"}))
                        trust_selected = true
                    end
                elseif provider ~= "claude" or frame:match("❯%s+Yes") then
                    save("trust-enter.txt", frame)
                    assert(view:send({type = "key", key = "enter", key_type = "enter", action = "press"}))
                    trust_sent = true
                end
            elseif not theme_sent and (frame:find("Choose the text style", 1, true) or frame:find("Choose a theme", 1, true)) then
                assert(view:send({type = "key", key = "", key_type = "enter", action = "press"}))
                theme_sent = true
            elseif (provider == "claude" and not frame:find("Welcome to", 1, true) and not frame:find("Enter to confirm", 1, true)
                and not frame:find("Accessing workspace", 1, true) and frame:find("Claude Code", 1, true) and (frame:find("❯", 1, true) or frame:find("Try", 1, true)))
                or (provider == "codex" and not frame:lower():find("trust", 1, true) and not frame:lower():find("loading", 1, true)
                    and trust_sent and frame:find("OpenAI Codex", 1, true) and frame:find("›", 1, true)) then
                save(provider .. "-ready.txt", frame); ready = true; break
            end
            time.sleep("25ms")
        end
        assert(ready, "provider PTY never became ready; see startup frame")
        local marker = "BEE_DOCKER_" .. provider:upper() .. "_OK"
        assert(view:send({type = "paste", text = "Respond with " .. marker .. ". Do not use tools."}))
        assert(view:send({type = "key", key = "", key_type = "enter", action = "press"}))
        local replied = false
        for index = 1, 3600 do
            local frame = plain(table.concat(assert(view:snapshot()).rows, "\n"))
            if index % 80 == 0 then save(provider .. "-turn.txt", frame) end
            for line in frame:gmatch("[^\n]+") do
                if line:find(marker, 1, true) and not line:find("Respond with", 1, true) then replied = true end
            end
            if replied then save(provider .. "-reply.txt", frame); break end
            time.sleep("25ms")
        end
        assert(replied, "provider did not reply in the Docker PTY")
        assert(view:send({type = "resize", width = 120, height = 32}))
        assert(process.send(broker, "bee.app.request", {version = 1, request_id = "detach", op = "bind", workspace_id = WORKSPACE, recipient = ""}))
        assert(receive(replies, "detach", "bind").error_code == "")
        assert(process.send(broker, "bee.app.request", {version = 1, request_id = "rebind", op = "bind", workspace_id = WORKSPACE,
            id = opened.id, instance_id = opened.instance_id, recipient = owner}))
        local rebound = receive(replies, "rebind", "attached")
        assert(rebound.error_code == "")
        local next_view = assert(tty.attach(tostring(rebound.mount)))
        save(provider .. "-rebound.txt", plain(table.concat(assert(next_view:snapshot()).rows, "\n")))
        next_view:close()
    end)
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "close", op = "close", workspace_id = WORKSPACE, id = opened.id}))
    local closed = receive(replies, "close", "close")
    assert(closed.error_code == "", tostring(closed.error))
    view:close()
    local db = assert(placement_store.open())
    local rows = assert(db:query("SELECT attempt_id FROM bee_placement_attempts WHERE placement_kind = 'docker'", {}))
    assert(#rows == 1, "window proof must own exactly one attempt")
    local attempt_id = assert(bounds.id(rows[1].attempt_id))
    local cleanup_deadline = time.after("30s")
    while true do
        local attempt = assert(placement_store.attempt(db, attempt_id))
        if attempt.cleanup_state == "complete" then
            local evidence = assert(placement_store.evidence(db, attempt_id, 0, 128))
            local verified_at, removed_at = 0, 0
            for index, item in ipairs(evidence.evidence) do
                if item.kind == "docker.exit_verified" then verified_at = index end
                if item.kind == "docker.removed" then removed_at = index end
            end
            assert(verified_at > 0 and removed_at > verified_at, "window removal must follow daemon exit evidence")
            save("closed-attempt.json", assert(json.encode(attempt)))
            save("close-evidence.json", assert(json.encode(evidence)))
            break
        end
        local poll = time.after("50ms")
        local selected = channel.select({poll:case_receive(), cleanup_deadline:case_receive()})
        assert(selected.ok and selected.channel == poll, "window cleanup did not complete before owner shutdown")
    end
    db:release()
    process.terminate(broker)
    process.unlisten(catalogs); process.unlisten(replies)
    if not ok then error(tostring(failure)) end
end
local function session(provider: string, definition: string, profile_id: string, resolved: admission.Plan, crash: boolean?)
    local marker = "BEE_DOCKER_" .. provider:upper() .. "_TURN_OK"
    local admitted, refused = admission.admit_request({request_id = provider .. "-turn", definition_ref = definition,
        workspace_id = WORKSPACE, brief = crash and "Use Bash to sleep 90 seconds, then respond with OWNER_RESTART_OK." or "Respond with " .. marker .. ". Do not use tools.", mode = "batch",
        saved_profile_id = profile_id, saved_profile_revision = 1, expected_plan_digest = resolved.plan_digest,
        thread_title = provider .. " Docker placement turn"})
    assert(admitted, tostring(refused and refused.error and refused.error.message))
    local io: machine.IO = {call = function(target: string, value: unknown): (unknown, string?)
        local raw, call_error = funcs.call(target, value)
        return raw, call_error and tostring(call_error) or nil
    end, send = function(target: string, topic: string, value: unknown) process.send(target, topic, value) end,
        self_pid = function(): string return tostring(process.pid()) end,
        now_ms = function(): integer return math.floor(time.now():unix_nano() / 1000000) end,
        key = function(): string return "docker-proof" end}
    local plan, plan_error = machine.plan(io, admitted.request)
    assert(plan, tostring(plan_error))
    local attempt = admitted.attempt_id
    local target = "bee.placement.docker.binding:"
    call(target .. "prepare", plan.placement_request)
    local output = assert(process.listen(protocol.TOPIC_OUTPUT, {message = true}))
    local exits = assert(process.listen(protocol.TOPIC_EXIT, {message = true}))
    call(target .. "attach", {attempt_id = attempt, recipient = process.pid(), generation = 1})
    local started = object(call(target .. "start", {attempt_id = attempt}).value)
    local runner = assert(bounds.id(started.runner))
    if crash then
        save("attempt.txt", attempt)
        save("started.json", assert(json.encode(started)))
        channel.select({time.after("180s"):case_receive()})
        error("owner was not killed during the restart proof")
    end
    local chunks: {string} = {}
    local stdout: {string} = {}
    local received_bytes = 0
    local ok, failure = pcall(function()
        local deadline = time.after("120s")
        local eof = 0
        local exited = false
        while eof < 2 or not exited do
            local selected = channel.select({output:case_receive(), exits:case_receive(), deadline:case_receive()})
            assert(selected.ok and selected.channel ~= deadline, "provider turn timed out")
            local message = selected.value
            assert(tostring(message:from()) == runner, "provider output has another sender")
            local data = object(message:payload():data())
            assert(data.attempt_id == attempt and data.generation == 1, "provider output has another attempt or generation")
            if selected.channel == exits then
                exited = true
            else
                assert(bounds.integer(data.sequence) and (data.stream == "stdout" or data.stream == "stderr") and type(data.eof) == "boolean", "malformed provider output")
                if type(data.data) == "string" then
                    received_bytes = received_bytes + #data.data
                    assert(received_bytes <= 1048576, "provider output exceeds evidence bound")
                    chunks[#chunks + 1] = data.data
                    save(provider .. "-stream.jsonl", table.concat(chunks))
                    if data.stream == "stdout" then stdout[#stdout + 1] = data.data end
                end
                assert(process.send(message:from(), protocol.TOPIC_ACK, {generation = 1, consumed_through = data.sequence}))
                if data.eof then eof = eof + 1 end
            end
        end
        local result = table.concat(chunks)
        save(provider .. "-stream.jsonl", result)
        local state: unknown = nil
        local terminal: Object? = nil
        local index = 0
        for line in table.concat(stdout):gmatch("[^\n]+") do
            local envelope, decode_error = json.decode(line)
            assert(not decode_error, "provider stdout contains a non-JSON frame")
            index = index + 1
            local normalized = call(plan.normalize_target, {state = state, index = index, envelope = envelope, eof = false, resumed = false})
            state = normalized.state
            if type(normalized.terminal) == "table" then terminal = object(normalized.terminal) end
        end
        local finished = call(plan.normalize_target, {state = state, index = index + 1, eof = true, resumed = false})
        if type(finished.terminal) == "table" then terminal = object(finished.terminal) end
        save(provider .. "-terminal.json", assert(json.encode(terminal)))
        assert(terminal and terminal.outcome == "succeeded" and type(terminal.answer) == "string"
            and terminal.answer:find(marker, 1, true), "provider has no successful normalized marker reply")
    end)
    call(target .. "stop", {attempt_id = attempt, mode = "forced"})
    call(target .. "cleanup", {attempt_id = attempt})
    process.unlisten(output); process.unlisten(exits)
    if not ok then error(tostring(failure)) end
end
local function recover()
    local volume = assert(fs.get("bee.docker.proof:evidence"))
    local attempt = assert(volume:readfile("/attempt.txt"))
    local target = "bee.placement.docker.binding:"
    local reconciled = object(call(target .. "reconcile", {attempt_id = attempt}).value)
    assert(reconciled.execution_state == "running", "restart did not identify the running container")
    save("reconciled.json", assert(json.encode(reconciled)))
    local repeated = object(call(target .. "start", {attempt_id = attempt}).value)
    assert(repeated.attempt_id == attempt, "restart returned another attempt")
    save("repeated-start.json", assert(json.encode(repeated)))
    local stopped = object(call(target .. "stop", {attempt_id = attempt, mode = "forced"}).value)
    assert(stopped.execution_state == "exited" and type(stopped.exit) == "table", "cancel has no daemon exit evidence")
    save("stopped.json", assert(json.encode(stopped)))
    call(target .. "cleanup", {attempt_id = attempt})
    save("evidence.json", assert(json.encode(call(target .. "evidence", {attempt_id = attempt, limit = 128}).value)))
end
local function scheduled(mode: string)
    local tools = {"session_catalog", "session_open", "session_run", "session_send", "session_await", "session_join", "session_get", "session_list", "session_cancel", "session_close", "thread_read", "thread_message"}
    local mcp: {{tool: string, scope: {[string]: unknown}}} = {}
    for _, tool in ipairs(tools) do mcp[#mcp + 1] = {tool = tool, scope = {}} end
    for _, provider in ipairs({"claude", "codex"}) do
        local id = provider .. "-docker-scheduler"
        call("bee.harness.profiles:call", {operation = "put", workspace_id = WORKSPACE, profile_id = id,
            expected_revision = 0, idempotency_key = id, profile = {schema_revision = "bee.agent-profile@2", name = id, definition_ref = "bee.driver." .. provider .. ":default_window", driver_binding_ref = "bee.driver." .. provider .. ":binding", placement = {kind = "docker", profile_ref = "bee.docker.proof:profile"}, provider = {}, bee = {mcp = mcp}}})
    end
    local function open(provider: string): Object
        return object(call("bee.sessions.binding:open", {spec = {definition = "bee.driver." .. provider .. ":default_window",
            profile = {id = provider .. "-docker-scheduler", revision = 1}}, operation_key = "open-" .. provider}).value)
    end
    local function wait(work: string): Object
        local deadline = time.after("5m")
        while true do
            local result = object(call("bee.sessions.binding:await", {subject = work}).value)
            if result.tag == "ready" then
                local outcome = object(result.result)
                assert(outcome.outcome == "succeeded", tostring(json.encode(outcome)))
                return result
            end
            assert(result.tag == "pending", tostring(json.encode(result)))
            local selected = channel.select({time.after("100ms"):case_receive(), deadline:case_receive()})
            assert(selected.ok and selected.channel ~= deadline, "scheduled Docker turn timed out")
        end
        error("scheduled turn unavailable")
    end
    local claude = open("claude")
    save("claude-open.json", assert(json.encode(claude)))
    local prompt = "Reply only with docker-claude-scheduler-ok."
    if mode == "child" then
        prompt = 'Use the Bee session_open MCP tool with spec {definition="bee.driver.codex:default_window",profile={id="codex-docker-scheduler",revision=1}} and operation_key "docker-child-open". Then session_send to that child with operation_key "docker-child-send" and input "Reply only with docker-child-codex-result-731.". Poll session_await on its returned work until ready, then return that exact child result. Use the Bee tools directly; do not invoke a local CLI.'
    end
    local sent = object(call("bee.sessions.binding:send", {session = claude.session, input = prompt, operation_key = "claude-work"}).value)
    save("claude-work.json", assert(json.encode(sent)))
    local result = wait(tostring(sent.work))
    save("claude-result.json", assert(json.encode(result)))
    if mode == "child" then
        assert(assert(json.encode(result)):find("docker%-child%-codex%-result%-731"), "Claude did not return its Codex child result")
    else
        local codex = open("codex")
        save("codex-open.json", assert(json.encode(codex)))
        local work = object(call("bee.sessions.binding:send", {session = codex.session, input = "Reply only with docker-codex-scheduler-ok.", operation_key = "codex-work"}).value)
        save("codex-work.json", assert(json.encode(work)))
        save("codex-result.json", assert(json.encode(wait(tostring(work.work)))))
    end
    save("sessions.json", assert(json.encode(call("bee.sessions.binding:list", {}).value)))
    local deadline = time.after("35s")
    while true do
        local db = assert(placement_store.open())
        local rows = assert(db:query("SELECT attempt_id, execution_state, cleanup_state FROM bee_placement_attempts WHERE placement_kind = 'docker'", {}))
        db:release()
        local complete = #rows > 0
        for _, row in ipairs(rows) do
            if row.execution_state ~= "exited" or row.cleanup_state ~= "complete" then complete = false end
        end
        if complete then save("cleanup.json", assert(json.encode(rows))); break end
        local event = channel.select({time.after("100ms"):case_receive(), deadline:case_receive()})
        assert(event.ok and event.channel ~= deadline, "Docker runner and sweeper did not complete container cleanup")
    end
end
function M.proof()
    local endpoint = object(assert(funcs.call("bee.gateway:address", {})))
    call("bee.gateway.binding:open", {address = endpoint.address})
    local expected = object(assert(registry.get("bee.docker.proof:expectation")).data)
    local provider, mode = tostring(expected.provider), tostring(expected.mode)
    if mode == "scheduler" or mode == "child" then scheduled(mode); return end
    if mode == "crash-recover" then recover(); return end
    save("image-readiness.json", assert(json.encode(call("bee.placement.docker.binding:capabilities", {placement_profile_ref = "bee.docker.proof:profile", runtime_name = provider}).value)))
    local definition, id, plan = profile(provider, mode == "window" and "window" or "session")
    if mode == "window" then window(provider, definition, id, plan)
    else session(provider, definition, id, plan, mode == "crash-start") end
end
return M
