-- MIT. Test-only proof that ordinary application scopes cannot open the
-- governance database directly, even when they hold a workspace operation.
local sql = require("sql")

local function handle(_: unknown): {opened: boolean}
    local database = sql.get("bee.governance:db")
    if database then
        database:release()
        return {opened = true}
    end
    return {opened = false}
end

return {handle = handle}
