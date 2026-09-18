-- MIT. Whether the caller may invoke a Hive operation: evaluated under the
-- caller's own actor and scope, so a mapped principal answers for itself
-- and no worker grant stands in for it.
local security = require("security")
local catalog = require("catalog")
local bounds = require("bounds")
local function handle(value: unknown): {allowed: boolean, operation_ref: string}
    local object = bounds.object(value) or {}
    local operation_ref = bounds.id(object.operation_ref) or ""
    return {allowed = operation_ref ~= "" and security.can(catalog.INVOKE, operation_ref), operation_ref = operation_ref}
end
return {handle = handle}
