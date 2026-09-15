-- MIT. Test helper to run dispatch under scoped security policies.
local dispatch = require("dispatch")
local types = require("types")

local function handle(request: unknown): types.Reply
    local decoded, err = types.decode_request(request)
    if not decoded then
        error("dispatch_probe received invalid request: " .. tostring(err))
    end
    return dispatch.dispatch(decoded)
end

return {handle = handle}
