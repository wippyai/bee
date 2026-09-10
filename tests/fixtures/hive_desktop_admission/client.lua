-- MIT. Lua native-client-role fixture; not the compiled physical client.
local process = require("process")
local time = require("time")
local channel = require("channel")
local tty = require("tty")
local uuid = require("uuid")
local types = require("types")
local protocol = require("protocol")
local contract = require("contract")
local function main(execution: string, scenario: string?, parent: string?)
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
    local function call(operation: string, input: unknown, key: string?): types.Reply
        local id = uuid.v7()
        local sent, send_error = process.send(target, types.TOPIC_REQUEST, {protocol_revision = types.REVISION,
            request_id = id, idempotency_key = key or id, owner_ref = {node_id = "node-0", service_id = protocol.SERVICE},
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
    if scenario == "hold" then
        if not parent then error("holder requires its parent") end
        local signals, err = process.listen("bee.desktop.fixture.hold", {message = true})
        if not signals then error(tostring(err)) end
        process.send(parent, "bee.desktop.fixture.held", "ready")
        while true do
            local selected = channel.select({signals:case_receive(), time.after("20s"):case_receive()})
            if not selected.ok or selected.channel ~= signals then error("holder timed out") end
            local message = selected.value
            if tostring(message:from()) ~= parent then error("foreign holder signal") end
            local op = message:payload():data()
            if op == "check" then
                command(view, "printf 'HELD_%s_OK\\n' \"$bee_mesh\"")
                text(view, "HELD_retained_OK")
                process.send(parent, "bee.desktop.fixture.held", "checked")
            elseif op == "stop" then
                local detached = call(protocol.DETACH, {owner_execution = execution, workspace_id = workspace_id, desktop_id = desktop_id, session_id = session})
                if not detached.ok then error("holder detach failed") end
                view:close()
                process.send(parent, "bee.desktop.fixture.held", "stopped")
                process.unlisten(signals); process.unlisten(replies)
                return
            else error("invalid holder signal") end
        end
    end
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
    -- Public catalog/create/attach routes use allocated identities; they cannot
    -- reuse the default session or expose another desktop's copy/launch grant.
    local held, held_error = process.listen("bee.desktop.fixture.held", {message = true})
    if not held then error(tostring(held_error)) end
    local holder, holder_error = process.spawn_monitored("bee.desktop_admission_probe:client", "bee.client:native", execution, "hold", tostring(process.pid()))
    if not holder then error(tostring(holder_error)) end
    local function held_reply(expected: string)
        local selected = channel.select({held:case_receive(), time.after("10s"):case_receive()})
        if not selected.ok or selected.channel ~= held then error("missing holder reply " .. expected) end
        local message = selected.value
        if tostring(message:from()) ~= tostring(holder) or message:payload():data() ~= expected then error("invalid holder reply") end
    end
    held_reply("ready")
    local busy = call(protocol.ATTACH, {owner_execution = execution, workspace_id = workspace_id, desktop_id = desktop_id, mode = "control"})
    if not busy.error or busy.error.code ~= "BUSY" then error("controller conflict is not a definite busy refusal") end
    local default_id = desktop_id
    desktop_id = "cccccccccccccccccccccccccccccccc"
    local create_input = {owner_execution = execution, workspace_id = workspace_id, desktop_id = desktop_id}
    local bad_key = call(protocol.CREATE, create_input)
    if not bad_key.error or bad_key.error.code ~= "INVALID_ARGUMENT" then error("allocation accepted an unrelated retry key") end
    local created = call(protocol.CREATE, create_input, desktop_id)
    if not created.ok then error("desktop allocation failed") end
    local replayed = call(protocol.CREATE, create_input, desktop_id)
    if not replayed.ok then error("desktop allocation replay failed") end
    local listed = call(protocol.LIST, {owner_execution = execution})
    local listed_value = listed.value
    if not listed.ok or type(listed_value) ~= "table" or type(listed_value.workspaces) ~= "table" then error("allocated catalog missing") end
    local listed_workspace = listed_value.workspaces[1]
    if type(listed_workspace) ~= "table" or type(listed_workspace.desktops) ~= "table" or #listed_workspace.desktops ~= 2 then error("allocation duplicated or missing") end
    local first, second = listed_workspace.desktops[1], listed_workspace.desktops[2]
    if type(first) ~= "table" or first.desktop_id ~= default_id or first.is_default ~= true
        or type(second) ~= "table" or second.desktop_id ~= desktop_id or second.is_default ~= false then error("catalog identity/default mismatch") end
    local dormant = call(protocol.ATTACH, {owner_execution = execution, workspace_id = workspace_id, desktop_id = desktop_id, mode = "observe"})
    if not dormant.error or dormant.error.code ~= "NOT_FOUND" then error("observation activated a dormant desktop") end
    local extra, extra_session = attach("control")
    local cross = call(protocol.COPY, {owner_execution = execution, workspace_id = workspace_id, desktop_id = default_id, session_id = extra_session})
    if not cross.error or cross.error.code ~= "CONFLICT" then error("session crossed desktop boundary") end
    local launched = call(protocol.LAUNCH, {owner_execution = execution, workspace_id = workspace_id, desktop_id = desktop_id,
        session_id = extra_session, name = "terminal", arguments = {}})
    if not launched.ok then error("selected desktop Terminal launch refused") end
    text(extra, "$ ")
    command(extra, "bee_extra=independent; printf 'EXTRA_%s_OK\\n' \"$bee_extra\"")
    text(extra, "EXTRA_independent_OK")
    process.send(tostring(holder), "bee.desktop.fixture.hold", "check")
    held_reply("checked")
    local extra_detached = call(protocol.DETACH, {owner_execution = execution, workspace_id = workspace_id, desktop_id = desktop_id, session_id = extra_session})
    if not extra_detached.ok then error("additional desktop detach refused") end
    extra:close()
    process.send(tostring(holder), "bee.desktop.fixture.hold", "stop")
    held_reply("stopped")
    process.unlisten(held)
    desktop_id = default_id
    local original, original_session = attach("control")
    command(original, "printf 'DEFAULT_%s_OK\\n' \"$bee_mesh\"")
    text(original, "DEFAULT_retained_OK")
    local original_detached = call(protocol.DETACH, {owner_execution = execution, workspace_id = workspace_id, desktop_id = desktop_id, session_id = original_session})
    if not original_detached.ok then error("default detach refused after additional desktop") end
    original:close()
    process.unlisten(replies)
end
return {main = main}
