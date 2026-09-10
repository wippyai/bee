-- MIT. Launch method resolve: the caller's actor, one operation.
local admission = require("admission")
local bounds = require("bounds")
local function handle(request: unknown): admission.Reply
    local object = bounds.object(request)
    if not object then return {ok = false, error = {code = "INVALID", message = "request must be an object"}, value = nil} end
    local plan, refused = admission.resolve(tostring(object.definition_ref), object.mode ~= nil and tostring(object.mode) or nil)
    if not plan then return refused :: admission.Reply end
    return {ok = true, error = nil, value = plan}
end 
return {handle = handle}
