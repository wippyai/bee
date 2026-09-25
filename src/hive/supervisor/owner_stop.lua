-- MIT. An enrolled local client asks the owner of its node to shut down
-- gracefully. The request names this node's owner service; with alone set it
-- stops only when no other local client is enrolled. The supervisor
-- authenticates the caller and answers; the owner's command process, which
-- the runtime waits on, accepts the stop only from the local supervisor and
-- ends the run. This library is pure.
local bounds = require("bounds")
local types = require("types")
local M = {}
M.SERVICE = "bee.hive.owner"
M.STOP = "bee.hive.owner:stop"
-- The host-named permission the supervisor needs to stop its owner.
M.ACTION = "hive.owner.stop"
-- The owner command process registers this name and receives the stop on
-- this topic.
M.COMMAND = "bee.launch.command"
M.TOPIC = "bee.owner.stop"
type Request = {alone: boolean}

function M.decode(call: types.Call, node: string): (Request?, types.Fault?)
    if call.owner_ref.node_id ~= node or call.owner_ref.resource_ref then
        return nil, types.fault("DENIED", "an owner stops only at the request of its own node's clients")
    end
    if call.target.operation_ref ~= M.STOP or call.target.interface_ref then
        return nil, types.fault("INVALID_ARGUMENT", "unknown owner operation")
    end
    local input = bounds.object(call.input)
    if not input then return nil, types.fault("INVALID_ARGUMENT", "input must be an object") end
    local unknown = bounds.fields(input, {"alone"})
    if unknown then return nil, types.fault("INVALID_ARGUMENT", unknown) end
    local alone = input.alone
    if type(alone) ~= "boolean" then return nil, types.fault("INVALID_ARGUMENT", "alone must be a boolean") end
    return {alone = alone}, nil
end

-- Whether the owner stops for this caller given the local clients enrolled now.
function M.stops(request: Request, caller: string, local_clients: {[string]: boolean}): boolean
    if not request.alone then return true end
    for client in pairs(local_clients) do
        if client ~= caller then return false end
    end
    return true
end

-- Whether a stop message came from this node's own supervisor.
function M.from_supervisor(sender: string, supervisor: string?): boolean
    return supervisor ~= nil and sender == supervisor
end

return M
