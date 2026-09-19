local funcs = require("funcs")
local http_client = require("http_client")
local json = require("json")
local time = require("time")
local client = require("client")
local channel = require("channel")
local process = require("process")
local tty = require("tty")
local fs = require("fs")
local bounds = require("bounds")

type Object = {[string]: unknown}
local TARGET = "bee.app_journey_demo:app"
local MISSING = "bee.app_open_probe:missing"

local function object(value: unknown): Object
    local decoded = bounds.object(value)
    if not decoded then error("expected object") end
    return decoded
end

local function call(target: string, request: Object): Object
    local reply, err = funcs.call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    return object(reply)
end

local function endpoint(): string
    for _ = 1, 100 do
        local selected, err = funcs.call("bee.gateway:address", {})
        local selected_object = bounds.object(selected)
        if not err and selected_object then
            local address = selected_object.address
            if type(address) == "string" and address:find("^127%.0%.0%.1:%d+$") then return address end
        elseif err and not tostring(err):find("gateway listener is starting", 1, true) then
            error("gateway address: " .. tostring(err))
        end
        time.sleep("20ms")
    end
    error("gateway listener did not become ready")
end

local function rpc(address: string, action: string, token: string, name: string, arguments: Object): Object
    local body = json.encode({jsonrpc = "2.0", id = 1, method = "tools/call", params = {name = name, arguments = arguments}})
    local response, err = http_client.post("http://" .. address .. "/mcp/" .. action,
        {headers = {Authorization = "Bearer " .. token, ["Content-Type"] = "application/json"}, body = body, timeout = "8s"})
    if not response then error("MCP request: " .. tostring(err)) end
    local decoded = json.decode(tostring(response.body))
    local envelope = object(decoded)
    if envelope.error ~= nil then
        local rpc_error = object(envelope.error)
        local code = rpc_error.code == -32602 and "INVALID_PARAMS" or tostring(rpc_error.code or "RPC_ERROR")
        return {error = {code = code, message = tostring(rpc_error.message or "")}}
    end
    local result = object(envelope.result)
    if type(result.content) ~= "table" then error("MCP result content is invalid") end
    local content = object(result.content[1])
    return object(json.decode(tostring(content.text)))
end

local function value(reply: Object, label: string): Object
    if reply.ok ~= true then error(label .. " failed: " .. tostring(json.encode(reply))) end
    return object(reply.value)
end

local function write_report(report: Object)
    local root = assert(fs.get("bee.app_open_probe:evidence"))
    local file = assert(root:open("/open.json", "w"))
    assert(file:write(json.encode(report)))
    file:close()
end

local function stage(name: string)
    write_report({stage = name})
end

local function direct_sender_probe(workspace_id: string): string
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
    return code
end

local function main(raw: unknown)
    stage("started")
    local launch = client.launch(raw)
    if not launch then error("invalid seed launch") end
    local lifecycle = assert(process.events())
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
    local address = endpoint()
    value(call("bee.gateway:open", {address = address}), "open gateway")
    stage("endpoint")
    local direct_code = direct_sender_probe(workspace_id)
    stage("direct:" .. direct_code)
    local admitted = value(call("bee.gateway:admit", {subject = "bee.app_open_probe", action_id = "open-probe", attempt_id = "open-probe-attempt",
        thread_id = "open-probe-thread", owner_incarnation = 1, carrier_epoch = 1, workspace_id = workspace_id,
        origin_view = {view_id = launch.view_id, instance_id = launch.instance_id},
        tools = {"application_open"}, ttl_ms = 60000}), "admit")
    stage("admitted")
    local binding = object(admitted.binding)
    local binding_id = tostring(binding.binding_id)
    local authorized = value(call("bee.gateway:authorize_materialization", {attempt_id = "open-probe-attempt", carrier_epoch = 1, binding_id = binding_id}), "authorize")
    local materialized = value(call("bee.gateway:materialize", {attempt_id = "open-probe-attempt", carrier_epoch = 1,
        binding_id = binding_id, materialization_key = tostring(authorized.materialization_key)}), "materialize")
    local token = tostring(materialized.token)
    local first = value(rpc(address, "open-probe", token, "application_open", {definition_id = TARGET, arguments = {}, idempotency_key = "open-1"}), "first open")
    local replay = value(rpc(address, "open-probe", token, "application_open", {definition_id = TARGET, arguments = {}, idempotency_key = "open-1"}), "replay open")
    local conflict = rpc(address, "open-probe", token, "application_open", {definition_id = TARGET, arguments = {"changed"}, idempotency_key = "open-1"})
    local missing = rpc(address, "open-probe", token, "application_open", {definition_id = MISSING, arguments = {}, idempotency_key = "missing-1"})
    local spoofed = rpc(address, "open-probe", token, "application_open", {definition_id = TARGET, arguments = {}, idempotency_key = "spoof-1", workspace_id = "foreign"})
    local first_id = bounds.id(first.view_id)
    local replay_id = bounds.id(replay.view_id)
    if not first_id or not replay_id or not bounds.id(first.instance_id) then error("open returned incomplete view identity") end
    local conflict_error = object(conflict.error)
    local missing_error = object(missing.error)
    local spoofed_error = object(spoofed.error)
    local report: Object = {workspace_id = workspace_id, first_id = first_id, replay_id = replay_id,
        replayed = replay.reused == true, conflict_code = conflict_error.code, missing_code = missing_error.code,
        spoofed_code = spoofed_error.code, direct_sender_code = direct_code,
        same_instance = first.instance_id == replay.instance_id}
    if type(first.display_id) ~= "string" or first.display_id == "" or first.display_id ~= replay.display_id then
        error("opened application has no stable display assignment")
    end
    if first_id == "" or first.instance_id ~= replay.instance_id or replay.reused ~= true then error("replay did not reuse the same instance") end
    if conflict_error.code ~= "request_conflict" then error("payload conflict was not reported") end
    if missing_error.code ~= "not_admitted" then error("unadmitted application was not refused by broker") end
    if spoofed_error.code ~= "INVALID_PARAMS" then error("caller supplied workspace was accepted") end
    if direct_code ~= "permission_denied" then error("unauthorized direct host sender was accepted: " .. direct_code) end
    report.passed = true
    write_report(report)
    while true do
        local event = channel.select({lifecycle:case_receive()})
        if not event.ok or event.value.kind == process.event.CANCEL then break end
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
