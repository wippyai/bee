local json = require("json")
local time = require("time")
local client = require("client")
local channel = require("channel")
local process = require("process")
local tty = require("tty")
local fs = require("fs")
local security = require("security")
local bounds = require("bounds")

type Object = {[string]: unknown}
local TARGET = "bee.app_journey_demo:app"
local THREAD = "open-probe-thread"
local OPERATOR = "bee.app.open.probe:operator"
local OPERATOR_SIGNAL = "bee.app.open.probe.operator.signal"
local OPERATOR_RESULT = "bee.app.open.probe.operator.result"

local function object(value: unknown): Object
    local decoded = bounds.object(value)
    if not decoded then error("expected object") end
    return decoded
end

local function write_report(report: Object)
    local root = assert(fs.get("bee.app.open.probe:evidence"))
    local file = assert(root:open("/open.json", "w"))
    assert(file:write(json.encode(report)))
    file:close()
end

local function stage(name: string)
    write_report({stage = name})
end

local function operator_pid(): string
    for _ = 1, 100 do
        local pid = process.registry.lookup(OPERATOR)
        if pid then return pid end
        time.sleep("20ms")
    end
    error("app-open operator did not become ready")
end

local function application_actor(launch: client.Launch): string
    local actor = security.actor()
    if not actor then error("application actor is unavailable") end
    local actor_id = actor:id()
    local expected = "bee.application:" .. launch.workspace_id .. ":" .. launch.instance_id
    if actor_id ~= expected then error("application actor is not host-derived") end
    return actor_id
end

local function direct_sender_probe(workspace_id: string): boolean
    local token = "bee.application.open/00000000-0000-7000-8000-000000000000"
    local registered = process.registry.register(token)
    if registered then error("ordinary application registered a protected open caller name") end
    local host = process.registry.lookup("bee.workspace.host/" .. workspace_id)
    if not host then error("workspace host is not registered") end
    local replies = assert(process.listen("bee.host.application.reply", {message = true}))
    local sent, send_error = process.send(host, "bee.host.application", {
        version = 1, workspace_id = workspace_id, request_id = "direct-auth-probe",
        definition_id = TARGET, arguments = {},
        caller_token = token,
    })
    if not sent then process.unlisten(replies); error("direct sender probe: " .. tostring(send_error)) end
    local deadline = time.after("2s")
    local code = ""
    while true do
        local selected = channel.select({replies:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then break end
        local message = selected.value
        if tostring(message:from()) == tostring(host) then
            local reply = bounds.object(message:payload():data())
            local nested = reply and bounds.object(reply.reply)
            if reply and nested and reply.request_id == "direct-auth-probe" then
                code = tostring(nested.error_code or "")
                break
            end
        end
    end
    process.unlisten(replies)
    return code == "" or code == "permission_denied"
end

local function main(raw: unknown)
    stage("started")
    local launch = client.launch(raw)
    if not launch then error("invalid seed launch") end
    local lifecycle = assert(process.events())
    local input = assert(tty.events())
    assert(tty.start())
    local surface = assert(tty.surface())
    local width, height = tty.screen_size()
    local canvas = tty.canvas(width, height)
    canvas:clear(" ")
    canvas:put(1, 1, "APP OPEN PROBE", width)
    assert(surface:present(canvas:rows()))
    client.ready(launch)
    stage("ready")
    local workspace_id = bounds.id(launch.workspace_id)
    if not workspace_id then error("seed launch has no workspace identity") end
    local actor_id = application_actor(launch)
    local results = assert(process.listen(OPERATOR_RESULT, {message = true}))
    local operator = operator_pid()
    local sent, send_error = process.send(operator, OPERATOR_SIGNAL, {workspace_id = workspace_id,
        view_id = launch.view_id, instance_id = launch.instance_id})
    if not sent then error("signal app-open operator: " .. tostring(send_error)) end
    stage("agent-started")
    local direct_refused = direct_sender_probe(workspace_id)
    stage("direct:" .. tostring(direct_refused))
    local deadline = time.after("60s")
    local managed: Object? = nil
    while not managed do
        local selected = channel.select({results:case_receive(), lifecycle:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then error("managed application opener timed out") end
        if selected.channel == lifecycle and selected.value.kind == process.event.CANCEL then error("application probe was cancelled") end
        if selected.channel == results and tostring(selected.value:from()) == tostring(operator) then
            local payload = object(selected.value:payload():data())
            if payload.workspace_id == workspace_id then managed = payload end
        end
    end
    process.unlisten(results)
    if managed.error ~= nil then error("managed application opener: " .. tostring(managed.error)) end
    local first_proof = object(managed.first_thread_proof)
    local second_proof = object(managed.second_thread_proof)
    if not first_proof or not second_proof then error("managed application proofs are missing") end
    local report: Object = {workspace_id = workspace_id, thread_id = THREAD, application_actor = actor_id,
        access_approval_id = managed.approval_id, first_id = managed.first_view, second_id = managed.second_view,
        first_instance = managed.first_instance, second_instance = managed.second_instance,
        window_id = managed.window_view, window_instance = managed.window_instance,
        removed_instance = managed.removed_instance, surviving_instance = managed.surviving_instance,
        removed_actor = managed.removed_actor, removed_access = managed.removed_access,
        surviving_access = managed.surviving_access,
        unapproved_refused = managed.unapproved_refused, direct_sender_refused = direct_refused,
        agent_exited = managed.agent_exited, managed_proof = managed.managed_proof,
        first_thread_proof = first_proof, second_thread_proof = second_proof}
    if not direct_refused then error("unauthorized direct host sender was accepted") end
    report.passed = true
    write_report(report)
    while true do
        local event = channel.select({lifecycle:case_receive(), input:case_receive()})
        if not event.ok then break end
        if event.channel == lifecycle and event.value.kind == process.event.CANCEL then break end
        if event.channel == input and event.value.type == "close" then break end
    end
    surface:close()
    tty.stop()
end

local function probe(raw: unknown)
    local ok, err = pcall(main, raw)
    if not ok then
        write_report({passed = false, error = tostring(err)})
        error(err)
    end
end

return {main = probe}
