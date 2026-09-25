-- MIT. Actual store access under the caller's admitted scope; no queries/writes.
local sql = require("sql")
local function run(): {[string]: boolean}
    local access: {[string]: boolean} = {}
    for _, resource in ipairs({"bee.environment:workspace_db", "bee.environment:client_db", "bee.placement.native:db", "bee.resources:db", "bee.credentials:db"}) do
        local db = sql.get(resource)
        access[resource] = db ~= nil
        if db then db:release() end
    end
    return access
end
return {run = run}
