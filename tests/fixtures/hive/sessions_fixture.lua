-- MIT
local process = require("process")
local env = require("env")
local registry = require("registry")
local system = require("system")
local security = require("security")
local funcs = require("funcs")
local fs = require("fs")
local json = require("json")
local time = require("time")
local exec = require("exec")
local protocol = require("protocol")
local bounds = require("bounds")
type Object = {[string]: unknown}
local WORKSPACE = "012345678901234567890123456789ab"
local M = {}
local function value(executor: funcs.Executor, target: string, arguments: Object): Object
    local raw, err = executor:call(target, arguments)
    assert(not err, tostring(err))
    local reply = assert(bounds.object(raw))
    assert(reply.ok == true, assert(json.encode(reply)))
    return assert(bounds.object(reply.value))
end
local function executor(actor: string, definition: string?): funcs.Executor
    local identity = assert(security.new_actor(actor, {workspace_id = WORKSPACE, definition_id = definition}))
    return funcs.new():with_actor(identity):with_scope(assert(security.new_scope({assert(security.policy("bee.e2e.sdk:fixture_policy")),
        assert(security.policy("bee.e2e.sdk:session_policy")), assert(security.policy("bee.threads.security:sessions_owner"))})))
end
local function journal(caller: funcs.Executor, method: string, arguments: Object): Object
    return value(caller, "bee.threads.binding:" .. method, arguments)
end
local function lookup(name: string): string
    for _ = 1, 300 do
        local found = process.registry.lookup(name, process.registry.EVENTUAL)
        if found then return tostring(found) end
        time.after("100ms"):receive()
    end
    error("fixture readiness deadline: " .. name)
end
local function register(name: string)
    assert(process.registry.register(name, process.pid(), process.registry.EVENTUAL))
end
local function warm(caller: funcs.Executor, session: string)
    local work = journal(caller, "work_send", {session = session, input = "fixture ready", operation_key = "warm/send"})
    local turn = journal(caller, "turn_reserve", {session = session, work = work.work, operation_key = "warm/reserve"})
    local input = journal(caller, "turn_pull", {turn = turn.turn, claim = turn.claim})
    journal(caller, "turn_accept", {turn = turn.turn, claim = turn.claim, input_digest = input.input_digest,
        checkpoint = {attempt_id = "fixture-attached"}, operation_key = "warm/accept"})
    journal(caller, "work_settle", {turn = turn.turn, claim = turn.claim, operation_key = "warm/settle",
        result = {state = "succeeded", schema = "bee:Text@1", value = {text = "ready"}}})
end
function M.activity(_arguments: unknown): Object return {ok = true, value = {}} end
function M.type_message(raw: unknown): Object
    local asked = assert(bounds.object(raw))
    local session = assert(bounds.id(asked.session))
    local caller = executor(session)
    value(caller, "bee.threads.sessions.binding:hook_boundary", {session = session, attempt_id = "fixture-attached",
        event = "UserPromptSubmit", input = asked.text, operation_key = "fixture/prompt"})
    local native = assert(exec.get("bee.placement.native.env:placement_executor"))
    local binary_root = env.get("bee.e2e.sdk:fixture_bin")
    local stream_value = env.get("bee.e2e.sdk:fixture_stream")
    local executable = assert(bounds.text(binary_root)) .. "/claude"
    local stream = assert(bounds.text(stream_value))
    local child = assert(native:exec(executable .. " --output-format stream-json", {env = {PATH = "/usr/bin:/bin", BEE_FIXTURE_STREAM = stream}}))
    local output = assert(child:stdout_stream())
    assert(child:start())
    local content = ""
    while true do
        local chunk: unknown = output:read(4096)
        if type(chunk) ~= "string" or chunk == "" then break end
        content = content .. chunk
    end
    child:wait()
    output:close()
    native:release()
    local answer: string? = nil
    for line in content:gmatch("[^\n]+") do
        local event = bounds.object((json.decode(line)))
        if event and event.type == "result" and event.subtype == "success" then answer = bounds.text(event.result) end
    end
    assert(answer == "Fixture reply across bees", "fixture driver did not produce its deterministic reply")
    value(caller, "bee.threads.sessions.binding:hook_boundary", {session = session, attempt_id = "fixture-attached",
        event = "Stop", answer = answer, operation_key = "fixture/stop"})
    return {ok = true, value = {}}
end
local function proof(): Object
    local node = assert(system.node.id())
    local label = assert(system.process.cwd()):match("([^/]+)$")
    assert(label == "alpha" or label == "beta")
    register("bee.e2e.sessions/" .. label)
    local peer = protocol.node_of(lookup("bee.e2e.sessions/" .. (label == "alpha" and "beta" or "alpha")), node)
    assert(peer ~= node)
    lookup("bee.e2e.sdk/ready/" .. label)
    local owner = executor("bee.application:" .. WORKSPACE .. ":session-fixture", "bee.harness.app:app")
    local opened = journal(owner, "session_create", {operation_key = "fixture/create", title = "Agent on " .. label,
        route = {delivery = "hook", definition = "bee.e2e.sdk:session_fixture"}})
    journal(owner, "session_attach", {session = opened.session, attempt_id = "fixture-attached", operation_key = "fixture/attach"})
    warm(owner, tostring(opened.session))
    if label == "beta" then
        local pinned = assert(registry.snapshot())
        local changes = pinned:changes()
        for name, destination in pairs({session_type = "present_type", session_activity = "present_activity"}) do
            local entry = assert(pinned:get("bee.e2e.sdk:" .. name))
            changes:update({id = "bee.harness.binding:" .. destination, kind = entry.kind, meta = entry.meta, data = entry.data})
        end
        assert(changes:apply())
        register("bee.e2e.sessions/ready/beta")
        lookup("bee.e2e.sessions/refused/alpha")
        value(owner, "bee.threads.sessions.binding:allowance", {operation = "grant", peer = peer, workspace_id = WORKSPACE, scope = "message"})
        register("bee.e2e.sessions/allowed/beta")
        return {ok = true, role = label, node = node, session = opened.session}
    end
    lookup("bee.e2e.sessions/ready/beta")
    local agent = executor(tostring(opened.session))
    local request: Object = {node = peer, filter = {workspace = WORKSPACE}}
    local refused = assert(bounds.object((agent:call("bee.threads.sessions.binding:list", request))))
    assert(refused.ok == false, "peer list must be refused before consent")
    register("bee.e2e.sessions/refused/alpha")
    lookup("bee.e2e.sessions/allowed/beta")
    local page = value(agent, "bee.threads.sessions.binding:list", request)
    local items = assert(bounds.dense_list(page.items, 64, "sessions"))
    assert(#items == 1, "beta owns exactly one fixture agent")
    local session = assert(bounds.id(assert(bounds.object(items[1])).session))
    local receipt = value(agent, "bee.threads.sessions.binding:send", {node = peer, session = session, input = "hello from alpha",
        operation_key = "cross-bee/send"})
    local replay = value(agent, "bee.threads.sessions.binding:send", {node = peer, session = session, input = "hello from alpha",
        operation_key = "cross-bee/send"})
    local sender = assert(bounds.object(receipt.sender))
    assert(sender.kind == "session" and sender.id == opened.session, "peer work preserves the source agent identity")
    assert(receipt.work == replay.work, "remote send replays its durable receipt")
    local observed = value(agent, "bee.threads.sessions.binding:await", {node = peer, subject = receipt.work, timeout_ms = 0})
    assert(observed.tag == "ready", assert(json.encode(observed)))
    local result = assert(bounds.object(observed.result))
    local answer = assert(bounds.object(result.value))
    assert(answer.text == "Fixture reply across bees", assert(json.encode(result)))
    return {ok = true, source_node = node, destination_node = peer, source_session = opened.session, destination_session = session,
        work = receipt.work, sender_session = sender.id, reply = answer.text, durable_replay = receipt.work == replay.work, default_denied = true}
end
function M.main()
    local events = assert(process.events())
    if env.get("bee:role") == "client" then events:receive(); return end
    local ok, result = pcall(proof)
    local volume = assert(fs.get("bee.env:workspace_root"))
    assert(volume:writefile("hive-sessions-proof.json", assert(json.encode(ok and result or {ok = false, error = tostring(result)}))))
    events:receive()
end
return M
