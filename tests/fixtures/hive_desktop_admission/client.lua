-- MIT. Lua native-client-role fixture; not the compiled physical client.
local process = require("process")
local time = require("time")
local channel = require("channel")
local tty = require("tty")
local uuid = require("uuid")
local types = require("types")
local protocol = require("protocol")
local contract = require("contract")
local function main(execution: string, scenario: string?)
    local replies, reply_error = process.listen(types.TOPIC_REPLY, {message = true})
    if not replies then error(tostring(reply_error)) end
    local target: string? = nil
    for _ = 1, 300 do
        local found = process.registry.lookup(types.SUPERVISOR_NAME .. "/node-0")
        if found then target = tostring(found); break end
        time.sleep("100ms")
    end
    if not target then error("owner not discovered") end
    local node, host = types.pid_parts(target)
    if node ~= "node-0" or host ~= types.SUPERVISOR_HOST then error("wrong owner identity") end
    local function call(operation: string, input: unknown): types.Reply
        local id = uuid.v7()
        local sent, send_error = process.send(target, types.TOPIC_REQUEST, {protocol_revision = types.REVISION,
            request_id = id, idempotency_key = id, owner_ref = {node_id = "node-0", service_id = protocol.SERVICE},
            target = {operation_ref = operation}, input = input,
            deadline = time.now():add("3s"):utc():format("2006-01-02T15:04:05.000Z07:00")})
        if not sent then error(tostring(send_error)) end
        local timeout = time.after("4s")
        while true do
            local selected = channel.select({replies:case_receive(), timeout:case_receive()})
            if not selected.ok or selected.channel == timeout then error("missing desktop reply for " .. operation) end
            if selected.channel == replies then
                local message = selected.value
                if tostring(message:from()) ~= target then
                    error("invalid desktop reply sender")
                end
                local reply = types.decode_reply(message:payload():data())
                if not reply or reply.request_id ~= id then error("invalid desktop reply correlation") end
                return reply
            end
        end
        error("desktop reply loop ended")
    end
    local catalog = call(protocol.LIST, {owner_execution = execution})
    for _ = 1, 30 do
        if catalog.ok then break end
        if not catalog.error or catalog.error.code ~= "UNAVAILABLE" then error("list refused") end
        time.sleep("100ms")
        catalog = call(protocol.LIST, {owner_execution = execution})
    end
    local value = catalog.value
    if not catalog.ok or type(value) ~= "table" or value.owner_execution ~= execution
        or type(value.workspaces) ~= "table" then error("invalid catalog") end
    local workspace = value.workspaces[1]
    if type(workspace) ~= "table" or type(workspace.desktops) ~= "table" then error("missing workspace") end
    local workspace_id = contract.workspace_id(workspace.workspace_id)
    local desktop = workspace.desktops[1]
    if not workspace_id or type(desktop) ~= "table" then error("invalid workspace") end
    local desktop_id = contract.workspace_id(desktop.desktop_id)
    if not desktop_id then error("invalid desktop") end
    local function attach(mode: "control" | "observe"): (tty.Viewport, string)
        local reply = call(protocol.ATTACH, {owner_execution = execution, workspace_id = workspace_id, desktop_id = desktop_id, mode = mode})
        for _ = 1, 100 do
            if reply.ok then break end
            if not reply.error or (reply.error.code ~= "BUSY" and reply.error.code ~= "UNAVAILABLE") then break end
            -- These are definite refusal replies. Unknown outcomes are never retried.
            time.sleep("20ms")
            reply = call(protocol.ATTACH, {owner_execution = execution, workspace_id = workspace_id, desktop_id = desktop_id, mode = mode})
        end
        local result = reply.value
        if not reply.ok then error("attach refused: " .. tostring(reply.error and reply.error.message)) end
        if type(result) ~= "table" or result.owner_execution ~= execution or result.workspace_id ~= workspace_id
            or result.desktop_id ~= desktop_id or result.recipient ~= tostring(process.pid()) or result.mode ~= mode
            or type(result.session_id) ~= "string" or type(result.mount_ref) ~= "string" then error("invalid mount reply") end
        local session_id = result.session_id
        local mount_ref = result.mount_ref
        if type(session_id) ~= "string" or type(mount_ref) ~= "string" then error("invalid session") end
        local view, err = tty.attach(mount_ref)
        if not view then error(tostring(err)) end
        return view, session_id
    end
    local function text(view: tty.Viewport, needle: string)
        for _ = 1, 500 do
            local snapshot = view:snapshot()
            if snapshot and table.concat(snapshot.rows, "\n"):find(needle, 1, true) then return end
            time.sleep("10ms")
        end
        error("retained Terminal missing " .. needle)
    end
    local function command(view: tty.Viewport, command: string)
        local sent, err = view:send({type = "paste", text = command})
        if not sent then error(tostring(err)) end
        local entered, enter_error = view:send({type = "key", key = "", key_type = "enter", action = "press"})
        if not entered then error(tostring(enter_error)) end
    end
    local view, session = attach("control")
    if scenario == "exit" then return end
    text(view, "$ ")
    if scenario == "crash" then
        command(view, "bee_crash=retained; printf 'CRASH_%s_OK\\n' \"$bee_crash\"")
        text(view, "CRASH_retained_OK")
        error("injected client crash")
    elseif scenario == "recover" then
        command(view, "printf 'AFTER_CRASH_%s_OK\\n' \"$bee_crash\"")
        text(view, "AFTER_CRASH_retained_OK")
        local recovered = call(protocol.DETACH, {owner_execution = execution, workspace_id = workspace_id, desktop_id = desktop_id, session_id = session})
        if not recovered.ok then error("recovered client detach failed") end
        view:close()
        process.unlisten(replies)
        return
    end
    command(view, "bee_mesh=retained; printf 'MESH_%s_OK\\n' \"$bee_mesh\"")
    text(view, "MESH_retained_OK")
    local wrong = call(protocol.DETACH, {owner_execution = execution, workspace_id = workspace_id, desktop_id = desktop_id, session_id = "foreign-session"})
    if not wrong.error or wrong.error.code ~= "DENIED" then error("foreign session accepted") end
    local detached = call(protocol.DETACH, {owner_execution = execution, workspace_id = workspace_id, desktop_id = desktop_id, session_id = session})
    if not detached.ok then error("detach failed") end
    local stale_sent = view:send({type = "paste", text = "forbidden"})
    if stale_sent then error("retired mount retained input authority") end
    view:close()
    local rejoined, second_session = attach("control")
    text(rejoined, "MESH_retained_OK")
    command(rejoined, "printf 'REJOIN_%s_OK\\n' \"$bee_mesh\"")
    text(rejoined, "REJOIN_retained_OK")
    local foreign = call(protocol.ATTACH, {owner_execution = execution, workspace_id = "dddddddddddddddddddddddddddddddd", desktop_id = desktop_id, mode = "control"})
    if not foreign.error or foreign.error.code ~= "NOT_FOUND" then error("foreign workspace accepted") end
    local second_detach = call(protocol.DETACH, {owner_execution = execution, workspace_id = workspace_id, desktop_id = desktop_id, session_id = second_session})
    if not second_detach.ok then error("second detach failed") end
    rejoined:close()
    local observer, observer_session = attach("observe")
    text(observer, "REJOIN_retained_OK")
    local observed_input = observer:send({type = "paste", text = "forbidden"})
    if observed_input then error("observer gained input authority") end
    local observer_detach = call(protocol.DETACH, {owner_execution = execution, workspace_id = workspace_id, desktop_id = desktop_id, session_id = observer_session})
    if not observer_detach.ok then error("observer detach failed") end
    observer:close()
    process.unlisten(replies)
end
return {main = main}
