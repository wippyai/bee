-- MIT. Explicit test host grants; no fixture identity grants itself authority.
local process = require("process")
local security = require("security")
local time = require("time")
local channel = require("channel")
local io = require("io")
local system = require("system")
local types = require("types")
type Channel = channel.Channel
local EXECUTION = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
local function main(node: string)
    local events, events_error = process.events()
    if not events then error(tostring(events_error)) end
    local supervisor: string? = nil
    local releases: Channel<process.Message>? = nil
    if node == "node-0" or node == "node-1" then
        if node == "node-0" then
            local registered, register_error = process.registry.register("bee.desktop_admission_probe.release")
            if not registered then error(tostring(register_error)) end
            releases = assert(process.listen("bee.desktop.fixture.released", {message = true}))
        end
        -- The service starts under its host-selected grants. A published name
        -- is its readiness event; the command starts no process host itself.
        local guard = time.after("45s")
        local ticker = time.ticker("100ms")
        while true do
            local named = process.registry.lookup(types.SUPERVISOR_NAME .. "/" .. node)
            if named then
                supervisor = tostring(named)
                local monitored, monitor_error = process.monitor(supervisor)
                if not monitored then error(tostring(monitor_error)) end
                break
            end
            local observed = channel.select({events:case_receive(), ticker:channel():case_receive(), guard:case_receive()})
            if not observed.ok or observed.channel == guard then error("node supervisor did not publish its name") end
        end
        ticker:stop()
    end
    local addr, address_error = system.node.addr()
    if not addr then error(tostring(address_error)) end
    io.print("BEE_HIVE_SUPERVISOR ready " .. tostring(addr))
    while true do
        local command, command_error = io.readline()
        if not command then error(tostring(command_error)) end
        if command:sub(1, 14) == "await_release " and releases then
            local recipient = command:sub(15)
            local guard = time.after("45s")
            while true do
                local selected = channel.select({releases:case_receive(), events:case_receive(), guard:case_receive()})
                if not selected.ok or selected.channel == guard then error("controller release did not complete for " .. recipient) end
                if selected.channel == events and selected.value.kind == process.event.EXIT then error("owner exited before controller release") end
                if selected.channel == releases then
                    local data: unknown = selected.value:payload():data()
                    if type(data) == "table" and data.recipient == recipient then break end
                end
            end
            io.print("BEE_HIVE_SUPERVISOR released " .. recipient)
        elseif command == "probe" or command == "crash" or command == "recover" or command == "exit" then
            local policy, err = security.policy("bee.desktop_admission_probe:client_policy")
            if not policy then error(tostring(err)) end
            local child, spawn_error = process.with_options({}):with_scope(security.new_scope({policy}))
                :spawn_monitored("bee.desktop_admission_probe:client", "bee.hive_host.desktop:display_host", EXECUTION, command)
            if not child then error(tostring(spawn_error)) end
            local timeout = time.after("45s")
            while true do
                local selected = channel.select({events:case_receive(), timeout:case_receive()})
                if not selected.ok or selected.channel == timeout then error("desktop probe timed out") end
                if selected.channel == events and selected.value.kind == process.event.EXIT then
                    if tostring(selected.value.from) ~= tostring(child) then error("unexpected owner exit") end
                    local result: unknown = selected.value.result
                    if command == "crash" then
                        if type(result) ~= "table" or result.error == nil or not tostring(result.error):find("injected client crash", 1, true) then
                            error("client did not reach its injected crash")
                        end
                    elseif type(result) == "table" and result.error ~= nil then error(tostring(result.error)) end
                    break
                end
            end
            io.print("BEE_HIVE_SUPERVISOR probe_passed" .. ((command == "crash" or command == "exit") and " " .. tostring(child) or ""))
        elseif command == "stop" then
            if releases then process.unlisten(releases); process.registry.unregister("bee.desktop_admission_probe.release") end
            io.print("BEE_HIVE_SUPERVISOR stopped")
            return
        else error("unknown fixture command") end
    end
end
return {main = main}
