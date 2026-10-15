local funcs = require("funcs")
local function handle(request: unknown): unknown
    if type(request) ~= "table" or request.operation ~= "publish" then
        return {ok = false, code = "DENIED", message = "The publish tool requires operation publish", replayed = false}
    end
    local result, err = funcs.call("bee.gov.binding:delivery_call", request)
    if err then return {ok = false, code = "UNAVAILABLE", message = tostring(err), replayed = false} end
    return result
end
return {handle = handle}
