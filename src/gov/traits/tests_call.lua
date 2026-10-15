local funcs = require("funcs")
local function handle(request: unknown): unknown
    local result, err = funcs.call("bee.node.binding:tests_call", request)
    if err then return {ok = false, error = {code = "UNAVAILABLE", message = tostring(err)}} end
    return result
end
return {handle = handle}
