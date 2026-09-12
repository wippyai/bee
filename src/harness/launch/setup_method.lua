-- MIT. First-use resource setup authenticates the caller before entering the
-- fixed host setup scope; metadata never grants workspace management.
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local BACKEND = "bee.harness.launch:setup_backend"
local SCOPE = "bee.harness.launch:harness_setup_execution_scope"
local function handle(raw: unknown): {[string]: unknown}
    local request = bounds.object(raw)
    if not request then return {ok = false, error = "request must be an object"} end
    if bounds.fields(request, {"workspace_id", "definition_ref"}) then return {ok = false, error = "unknown field"} end
    local workspace = bounds.id(request.workspace_id)
    if not workspace then return {ok = false, error = "workspace_id is not an identifier"} end
    if not security.can("bee.harness.setup", workspace) then return {ok = false, error = "setup is not authorized"} end
    local scope, scope_error = security.named_scope(SCOPE)
    if not scope then return {ok = false, error = tostring(scope_error or "setup scope unavailable")} end
    local executor, executor_error = funcs.new():with_scope(scope)
    if not executor then return {ok = false, error = tostring(executor_error or "setup scope denied")} end
    local result, call_error = executor:call(BACKEND, request)
    if call_error or type(result) ~= "table" then return {ok = false, error = tostring(call_error or "setup reply")} end
    return result :: {[string]: unknown}
end
return {handle = handle}
