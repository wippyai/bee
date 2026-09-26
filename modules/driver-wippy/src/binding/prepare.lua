-- MIT. Driver method prepare for native Wippy driver: the driver executes
-- in-process through bee.driver.wippy:run, so a placement launch is
-- refused with a typed error instead of describing a binary that
-- does not exist.
local bounds = require("bounds")

local function decode(request: unknown): ({[string]: unknown}?, string?)
    local object = bounds.object(request)
    if not object then return nil, "request must be an object" end
    local unknown_field = bounds.fields(object, {"profile_id", "brief", "resume_ref", "gateway_tools", "gateway_hooks", "permission_exchange", "control_enabled"})
    if unknown_field then return nil, unknown_field end
    local profile_id = bounds.id(object.profile_id)
    if not profile_id then return nil, "profile_id is not an identifier" end
    if object.brief ~= nil and not bounds.text(object.brief) then return nil, "brief must be bounded text" end
    return object, nil
end

local function handle(request: unknown): {[string]: unknown}
    local _, err = decode(request)
    if err then return {ok = false, error = err} end
    return {ok = false, error = "native driver executes in-process through bee.driver.wippy:run; placement launch is not supported"}
end

return {handle = handle}
