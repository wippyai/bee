-- MIT. Node settings: named string values kept in the node database.
local sql = require("sql")

local M = {}
M.DB = "bee:db"

-- get returns the value stored under key, or nil when none is stored.
function M.get(key: string): (string?, string?)
    local db, err = sql.get(M.DB)
    if not db then return nil, "node database: " .. tostring(err) end
    local rows, query_err = db:query("SELECT value FROM bee_node_settings WHERE key = ?", {key})
    db:release()
    if not rows then return nil, tostring(query_err) end
    if not rows[1] then return nil, nil end
    return tostring(rows[1].value), nil
end

-- set stores every key and value of values together, or none of them.
function M.set(values: {[string]: string}): (boolean, string?)
    local db, err = sql.get(M.DB)
    if not db then return false, "node database: " .. tostring(err) end
    local tx, begin_err = db:begin()
    if not tx then db:release(); return false, tostring(begin_err) end
    for key, value in pairs(values) do
        local _, exec_err = tx:execute(
            "INSERT INTO bee_node_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            {key, value})
        if exec_err then
            tx:rollback()
            db:release()
            return false, tostring(exec_err)
        end
    end
    local committed, commit_err = tx:commit()
    db:release()
    if not committed then return false, tostring(commit_err) end
    return true, nil
end

return M
