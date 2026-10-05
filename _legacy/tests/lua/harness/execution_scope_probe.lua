-- MIT. Actual store access under the caller's admitted scope; no queries/writes.
local sql = require("sql")
local function run(): {[string]: boolean}
    local access: {[string]: boolean} = {}
    for _, resource in ipairs({"bee.env:workspace_db", "bee.env:client_db", "bee.placement.native.env:db", "bee.resources.env:db", "bee.credentials.env:db"}) do
        local db = sql.get(resource)
        access[resource] = db ~= nil
        if db then db:release() end
    end
    return access
end
return {run = run}
