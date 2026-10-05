-- MIT. Opens the node database. wippy/migration applies every component's
-- migration entries that target it at boot.
local sql = require("sql")
local M = {}
M.RESOURCE = "bee:db"
function M.open(): (sql.DB?, string?)
    local db, err = sql.get(M.RESOURCE)
    if not db then return nil, "node database: " .. tostring(err) end
    return db, nil
end
return M
