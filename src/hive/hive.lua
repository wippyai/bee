-- MIT
local funcs = require("funcs")
local M = {}
function M.call(request: unknown): (unknown?, string?)
    local reply, err = funcs.new():with_options({retry = {max_attempts = 1}}):call("bee.hive.binding:call", request)
    if err then return nil, tostring(err) end
    if type(reply) ~= "table" or type(reply.ok) ~= "boolean" then return nil, "invalid Hive facade reply" end
    if reply.ok then return reply.value, nil end
    local fault: unknown = reply.error
    return nil, type(fault) == "table" and type(fault.message) == "string" and fault.message or "Hive call refused"
end
return M
