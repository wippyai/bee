-- MIT. Deliberately has no attached storage policy.
local sql = require("sql")
local function handle(): boolean
    local db, err = sql.get("bee.node:db")
    if db then db:release(); return true end
    return false
end
return {handle = handle}
