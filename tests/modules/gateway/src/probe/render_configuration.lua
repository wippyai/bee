-- MIT. A real function call under a caller-selected, minimal rendering scope.
-- The scope controls security checks for the callee. Actor and arbitrary
-- context values are still inherited by funcs.new():call(); this probe makes
-- no claim that scope selection is a complete context isolation boundary.
local exec = require("exec")
local funcs = require("funcs")
local security = require("security")
local sql = require("sql")
local configuration = require("configuration")
type Object = {[string]: unknown}

local function run(request: Object): Object
    local address = request.address
    local action_id = request.action_id
    assert(type(address) == "string" and type(action_id) == "string", "render request")
    local projection, render_error = configuration.projection(address :: string, action_id :: string)
    assert(projection and not render_error, "configuration projection: " .. tostring(render_error))

    local placement_db, placement_error = sql.get("bee.placement.native:db")
    local placement_executor, executor_error = exec.get("bee.placement.native:executor")
    local placement_policy, policy_error = security.policy("bee:placement_store_policy")
    local current_scope = security.scope()
    local recovered_scope, recovered_error = funcs.new():with_scope(current_scope)
    local created, create_error = pcall(function()
        return security.new_scope({})
    end)

    return {
        projection = projection,
        placement_db_denied = placement_db == nil and placement_error ~= nil,
        placement_executor_denied = placement_executor == nil and executor_error ~= nil,
        placement_policy_denied = placement_policy == nil and policy_error ~= nil,
        funcs_security_denied = recovered_scope == nil and recovered_error ~= nil,
        scope_create_denied = not created and create_error ~= nil,
    }
end

return {run = run}
