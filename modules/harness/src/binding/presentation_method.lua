-- MIT. Application callers retain their identity across the host execution boundary.
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local M = {}
function M.open(value: unknown): {[string]: unknown}
    local scope = assert(security.named_scope("bee.harness.security:presentation_execution_scope"))
    local executor = assert(funcs.new():with_scope(scope))
    local reply, err = executor:call("bee.harness.service:open", value)
    local result = bounds.object(reply)
    if err or not result then return {ok = false, error = {code = "UNAVAILABLE", message = tostring(err or "presentation reply unavailable")}} end
    return result
end
return M
