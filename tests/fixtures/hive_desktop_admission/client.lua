-- MIT. Lua native-client-role fixture; not the compiled physical client.
local process = require("process")
local time = require("time")
local channel = require("channel")
local uuid = require("uuid")
local types = require("types")
local protocol = require("protocol")
local contract = require("contract")
local display = require("display")
local OWNER_OS = "__BEE_OWNER_OS__"
local OWNER_PROOF = "__BEE_OWNER_PROOF__"
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
                local reply, decode_error = types.decode_reply(message:payload():data())
                if not reply then error("invalid " .. operation .. " reply: " .. tostring(decode_error)) end
                if reply.request_id ~= id then error("invalid desktop reply correlation for " .. operation) end
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
        or type(value.workspaces) ~= "table" or type(value.desktops) ~= "table" then error("invalid catalog") end
    -- The owner composes its folder workspace; displays belong to the node.
    local workspace_id = contract.workspace_id(value.default_workspace)
    local desktop = value.desktops[1]
    if not workspace_id or type(desktop) ~= "table" then error("invalid workspace") end
    local desktop_id = contract.workspace_id(desktop.desktop_id)
    if not desktop_id then error("invalid desktop") end
    -- The raw catalog probe has done its single read. Presentation owns its
    -- own Hive reply subscription, so the fixture cannot retain this one.
    process.unlisten(replies)
    local function attach(mode: "control" | "observe")
        local target, target_error = display.target("node-0", execution, workspace_id, desktop_id, mode)
        if not target then error(tostring(target_error)) end
        local view, open_error = display.open(target)
        if not view then error("display attach refused: " .. tostring(open_error and open_error.message)) end
        return view
    end
    local function text(view, needle: string)
        for _ = 1, 500 do
            local snapshot = display.content(view, 120, 40)
            if snapshot and table.concat(snapshot.rows, "\n"):find(needle, 1, true) then return end
            time.sleep("10ms")
        end
        error("retained Terminal missing " .. needle)
    end
    local function command(view, command: string)
        local sent, err = display.send(view, {type = "paste", text = command})
        if not sent then error(tostring(err)) end
        local entered, enter_error = display.send(view, {type = "key", key = "", key_type = "enter", action = "press"})
        if not entered then error(tostring(enter_error)) end
    end
    local view = attach("control")
    if not display.resize(view, 120, 40) then error("control resize refused") end
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
                local detached, detach_error = display.close(view)
                if not detached then error("holder detach failed: " .. tostring(detach_error)) end
                process.send(parent, "bee.desktop.fixture.held", "stopped")
                process.unlisten(signals)
                return
            else error("invalid holder signal") end
        end
    end
    if scenario == "exit" then return end
    text(view, "$ ")
    command(view, "printf 'OWNER_OS_%s\\n' \"$(uname -s)\"")
    text(view, "OWNER_OS_" .. OWNER_OS)
    command(view, "printf 'OWNER_FILE_%s\\n' \"$(cat desktop-owner-proof)\"")
    text(view, "OWNER_FILE_" .. OWNER_PROOF)
    if scenario == "crash" then
        command(view, "bee_crash=retained; printf 'CRASH_%s_OK\\n' \"$bee_crash\"")
        text(view, "CRASH_retained_OK")
        error("injected client crash")
    elseif scenario == "recover" then
        command(view, "printf 'AFTER_CRASH_%s_OK\\n' \"$bee_crash\"")
        text(view, "AFTER_CRASH_retained_OK")
        local recovered, recovery_error = display.close(view)
        if not recovered then error("recovered client detach failed: " .. tostring(recovery_error)) end
        return
    end
    command(view, "bee_mesh=retained; printf 'MESH_%s_OK\\n' \"$bee_mesh\"")
    text(view, "MESH_retained_OK")
    local detached, detach_error = display.close(view)
    if not detached then error("detach failed: " .. tostring(detach_error)) end
    if display.send(view, {type = "paste", text = "forbidden"}) then error("retired mount retained input authority") end
    local rejoined = attach("control")
    text(rejoined, "MESH_retained_OK")
    command(rejoined, "printf 'REJOIN_%s_OK\\n' \"$bee_mesh\"")
    text(rejoined, "REJOIN_retained_OK")
    local rejoined_detached, rejoined_error = display.close(rejoined)
    if not rejoined_detached then error("rejoined detach failed: " .. tostring(rejoined_error)) end
    local observer = attach("observe")
    text(observer, "REJOIN_retained_OK")
    if display.send(observer, {type = "paste", text = "forbidden"}) then error("observer gained input authority") end
    if display.resize(observer, 120, 40) then error("observer gained resize authority") end
    local observer_detached, observer_error = display.close(observer)
    if not observer_detached then error("observer detach failed: " .. tostring(observer_error)) end
    local held, held_error = process.listen("bee.desktop.fixture.held", {message = true})
    if not held then error(tostring(held_error)) end
    local holder, holder_error = process.spawn_monitored("bee.desktop.admission.probe:client", "bee.hive.desktop:display_host", execution, "hold", tostring(process.pid()))
    if not holder then error(tostring(holder_error)) end
    local function held_reply(expected: string)
        local selected = channel.select({held:case_receive(), time.after("10s"):case_receive()})
        if not selected.ok or selected.channel ~= held then error("missing holder reply " .. expected) end
        local message = selected.value
        if tostring(message:from()) ~= tostring(holder) or message:payload():data() ~= expected then error("invalid holder reply") end
    end
    held_reply("ready")
    local conflict_target, target_error = display.target("node-0", execution, workspace_id, desktop_id, "control")
    if not conflict_target then error(tostring(target_error)) end
    local conflict, conflict_error = display.open(conflict_target)
    if conflict or not conflict_error or conflict_error.code ~= "DESKTOP_CONTROLLED" then error("controller conflict was not a typed refusal") end
    process.send(tostring(holder), "bee.desktop.fixture.hold", "stop")
    held_reply("stopped")
    process.unlisten(held)
    local final = attach("control")
    text(final, "REJOIN_retained_OK")
    local final_detached, final_error = display.close(final)
    if not final_detached then error("final detach failed: " .. tostring(final_error)) end
end
return {main = main}
