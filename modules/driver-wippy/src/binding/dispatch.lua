-- MIT. Driver method dispatch for native Wippy driver: continuations run
-- in-process through bee.driver.wippy:run, so a placement dispatch is
-- refused with a typed error instead of describing a binary that
-- does not exist.
local bounds = require("bounds")

local function handle(request: unknown): {[string]: unknown}
    local object = bounds.object(request)
    if not object then return {ok = false, error = "request must be an object"} end
    local unknown_field = bounds.fields(object, {"profile_id", "brief", "resume_ref", "gateway_tools", "gateway_hooks", "permission_exchange", "control_enabled"})
    if unknown_field then return {ok = false, error = unknown_field} end
    if not bounds.id(object.resume_ref) then return {ok = false, error = "a dispatched turn needs resume_ref"} end
    return {ok = false, error = "native driver executes in-process through bee.driver.wippy:run; placement dispatch is not supported"}
end

return {handle = handle}
