local bounds = require("bounds")
local configuration = require("configuration")
local M = {}
function M.handle(raw: unknown): {[string]: unknown}
    local value = bounds.object(raw)
    local target = value and bounds.id(value.target)
    if not value or not target then return {error = "Agent configuration needs a driver target."} end
    local binding = value.binding_ref == nil and nil or bounds.id(value.binding_ref)
    if value.binding_ref ~= nil and not binding then return {error = "Agent configuration needs a valid binding."} end
    local delivery, err = configuration.execute(binding, target, value.request)
    return {delivery = delivery, error = err}
end
return M
