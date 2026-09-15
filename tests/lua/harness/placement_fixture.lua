-- MIT. Test carriers use the same registry-backed placement selection as
-- launch admission. The helper intentionally returns the measured binding
-- identity and method targets rather than fabricating fixture values.
local registry = require("registry")
local resolver = require("resolver")
local M = {}
type Placement = {binding_id: string, binding_digest: string, methods: {[string]: string}}
function M.resolve(): Placement
    local selected, err = resolver.resolve(registry.snapshot(), nil)
    if not selected then error("resolve fixture placement: " .. tostring(err)) end
    return selected
end
return M
