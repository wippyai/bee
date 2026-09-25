-- MIT. The stop an owner or daemon command accepts from its local Hive
-- supervisor. The runtime waits on the command, so the command ends the run:
-- it requests the runtime's graceful shutdown and returns.
local process = require("process")
local channel = require("channel")
local system = require("system")
local owner_stop = require("owner_stop")
local types = require("types")
local M = {}
type Channel = channel.Channel
type Listener = {channel: Channel<process.Message>}

-- Names this command and listens for the forwarded stop.
function M.open(): (Listener?, string?)
    local stops, stops_error = process.listen(owner_stop.TOPIC, {message = true})
    if not stops then return nil, tostring(stops_error) end
    local named, name_error = process.registry.register(owner_stop.COMMAND)
    if not named then
        process.unlisten(stops)
        return nil, "register " .. owner_stop.COMMAND .. ": " .. tostring(name_error)
    end
    return {channel = stops}, nil
end

-- Whether a received stop ends this command; a stop from anywhere but the
-- local supervisor is ignored.
function M.accept(message: process.Message): boolean
    if not owner_stop.from_supervisor(tostring(message:from()), process.registry.lookup(types.SUPERVISOR_NAME)) then
        return false
    end
    local exited, exit_error = system.exit(0)
    if not exited then error("Owner stop: " .. tostring(exit_error)) end
    return true
end

function M.close(listener: Listener)
    process.registry.unregister(owner_stop.COMMAND)
    process.unlisten(listener.channel)
end

return M
