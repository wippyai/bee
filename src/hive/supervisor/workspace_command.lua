-- MIT. The supervisor's worker for one bee workspace command. It serves only
-- a caller the host granted the command, runs the catalog operation the
-- command names under this function's host-attached policies, and answers
-- with a Hive reply correlated to the supervisor's exchange identity.
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local types = require("types")
local commands = require("commands")

local function handle(value: unknown): types.Reply
    local object = bounds.object(value)
    local request_id = object and bounds.id(object.request_id) or nil
    if not object or not request_id then error("workspace command request needs a request_id") end
    local extra = bounds.fields(object, {"request_id", "operation", "idempotency_key", "input"})
    local operation = bounds.id(object.operation)
    local key = bounds.id(object.idempotency_key)
    local target = operation and commands.OPERATIONS[operation] or nil
    local input = bounds.object(object.input)
    if extra or not operation or not key or not target or not input then
        return types.reply_error(request_id, types.fault("INVALID_ARGUMENT", extra or "unknown workspace operation or input"))
    end
    if not security.can(commands.ACTION, operation) then
        return types.reply_error(request_id, types.fault("DENIED", "the caller may not run " .. operation))
    end
    local answer, err = funcs.new():call(target, input)
    if err then
        return types.reply_error(request_id, types.uncertain("workspace catalog call failed: " .. tostring(err):sub(1, 1024),
            {operation_ref = operation, idempotency_key = key}))
    end
    return commands.reply(request_id, {operation_ref = operation, idempotency_key = key}, answer)
end

return {handle = handle}
