-- MIT. Gateway method hook_queue: the queued and committed hook
-- submissions of one binding, for the carrier that commits them and for
-- proofs; the caller admits the action or manages bindings.
local security = require("security")
local bounds = require("bounds")
local gateway = require("gateway")
local function handle(request: unknown): gateway.Reply
    local object = bounds.object(request)
    if not object then return {ok = false, error = {code = "INVALID", message = "request must be an object"}} end
    local checked = gateway.check({binding_id = object.binding_id})
    if not checked.ok then return checked end
    local binding = checked.value :: gateway.Binding
    if not security.can(gateway.ADMIT, binding.action_id) and not security.can(gateway.MANAGE, "bindings") then
        return {ok = false, error = {code = "DENIED", message = "caller may not read this binding's hooks"}}
    end
    return gateway.hook_queue(binding)
end
return {handle = handle}
