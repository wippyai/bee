local funcs = require("funcs")
local function handle(request: unknown): unknown
    local result, err = funcs.call("bee.gov.binding:overlay_call", request)
    if err then return {ok = false, code = "UNAVAILABLE", message = tostring(err), replayed = false} end
    return result
end
return {handle = handle}
