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
    local provider, provider_error = configuration.decode("bee.gateway.probe:provider", {
        kind = "registry.entry", meta = {type = "bee.codex_provider"}, data = {
            schema_revision = "bee.codex-provider@1", name = "bee", base_url = "https://example.invalid/v1", model = "fixture"}})
    if not provider then error(tostring(provider_error)) end
    local section = configuration.gateway_section({endpoint = address :: string, action_id = action_id :: string,
        token_environment = "BEE_GATEWAY_TOKEN", tools = {"thread_read"}, hooks = {}})
    local projection, render_error = configuration.projection(provider, section)
    assert(projection and not render_error, "configuration projection: " .. tostring(render_error))

    if request.privileged == true then
        local placement_db, placement_error = sql.get("bee.placement.native:db")
        local placement_executor, executor_error = exec.get("bee:placement_executor")
        assert(placement_db and not placement_error, "privileged caller could not acquire placement database")
        assert(placement_executor and not executor_error, "privileged caller could not acquire placement executor")
        local _, release_db_error = placement_db:release()
        local _, release_executor_error = placement_executor:release()
        assert(not release_db_error and not release_executor_error, "privileged placement handles did not release")
        return {placement_db_acquired = true, placement_executor_acquired = true}
    end

    local placement_db, placement_error = sql.get("bee.placement.native:db")
    local placement_executor, executor_error = exec.get("bee:placement_executor")
    local placement_policy, policy_error = security.policy("bee.security.placement:placement_store_policy")
    local current_scope = security.scope()
    local recovered_scope, recovered_error = funcs.new():with_scope(current_scope)
    local created, create_error = pcall(function()
        return security.new_scope({})
    end)

    return {
        projection = projection,
        placement_db_denied = placement_db == nil and (placement_error and placement_error:kind()) == "PermissionDenied",
        placement_executor_denied = placement_executor == nil and tostring(executor_error):find("permission denied: access executor", 1, true) ~= nil,
        placement_policy_denied = placement_policy == nil and tostring(policy_error):find("permission denied: access policy", 1, true) ~= nil,
        funcs_security_denied = recovered_scope == nil and (recovered_error and recovered_error:kind()) == "PermissionDenied",
        scope_create_denied = not created and tostring(create_error):find("not allowed to create custom scopes", 1, true) ~= nil,
    }
end

return {run = run}
