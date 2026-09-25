-- MIT. Called under the same retained caller scope before and after authoring.
local sql = require("sql")
local security = require("security")
local function handle(): {opened: boolean, scope_create: boolean, scope_lookup: boolean, private_execute: boolean}
    local db = sql.get("bee.gov:db")
    if db then db:release() end
    return {opened = db ~= nil,
        scope_create = security.can("security.scope.create", "custom"),
        scope_lookup = security.can("security.policy_group.get", "bee.gov.security:workspace_execution_scope"),
        private_execute = security.can("bee.gov.workspace.execute", "bee.gov.binding:workspace_backend_call")}
end
return {handle = handle}
