-- MIT. Exercise the native registry with only the selected private owner scope.
local bounds = require("bounds")
local materializer = require("materializer")
local function apply(raw: unknown): {[string]: unknown}
    local request = assert(bounds.object(raw))
    local applied, apply_error = materializer.reconcile(request.owner, request.entries)
    local restored, restore_error = materializer.reconcile(request.owner, {})
    return {applied = applied ~= nil, message = apply_error,
        restored = restored ~= nil, restore_error = restore_error}
end
return {apply = apply}
