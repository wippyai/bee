-- MIT. The node daemon: runs the node's services from a folder's state without
-- composing the folder as a workspace. Workspace hosts start on their first
-- lease and desktops attach through the node's desktop bridge, so the daemon
-- only reports that the node serves and stays until it is stopped.
local process = require("process")
local channel = require("channel")
local time = require("time")
local io = require("io")
local system = require("system")
local logger = require("logger")
local leases = require("leases")
local command_stop = require("command_stop")
local types = require("types")

local function main()
    local events, events_error = process.events()
    if not events then error(tostring(events_error)) end
    -- The node serves once its host manager and Hive supervisor run.
    local deadline = time.after("10s")
    while not process.registry.lookup(leases.MANAGER) or not process.registry.lookup(types.SUPERVISOR_NAME) do
        local selected = channel.select({time.after("50ms"):case_receive(), deadline:case_receive(), events:case_receive()})
        if selected.channel == deadline then error("The node's host manager or Hive supervisor did not start") end
        if selected.channel == events and selected.value.kind == process.event.CANCEL then return end
    end
    local self = tostring(process.pid())
    local node = system.node.id()
    local seed = system.node.addr()
    if not node or node == "" or not seed or seed == "" then
        node, seed = "local", "-"
    end
    local stops, stops_error = command_stop.open()
    if not stops then error(stops_error) end
    logger:info("Bee daemon ready", {node = node})
    assert(io.print("BEE_DAEMON_READY " .. node .. " " .. seed .. " " .. self))
    while true do
        local selected = channel.select({events:case_receive(), stops.channel:case_receive()})
        if not selected.ok or (selected.channel == events and selected.value.kind == process.event.CANCEL) then break end
        if selected.channel == stops.channel and command_stop.accept(selected.value) then break end
    end
    command_stop.close(stops)
end

return {main = main}
