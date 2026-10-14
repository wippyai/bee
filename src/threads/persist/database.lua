-- MIT. Opens the node database that holds the Threads schema; wippy/migration
-- applies the bee.threads.migrations entries to it at boot.
local sql = require("sql")
local M = {}
M.RESOURCE = "bee:db"
function M.open(): (sql.DB?, string?)
    local db, err = sql.get(M.RESOURCE)
    if not db then return nil, "thread database: " .. tostring(err) end
    return db, nil
end
return M
