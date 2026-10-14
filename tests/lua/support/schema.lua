-- MIT. Gives a suite's own database a component's node schema: the
-- component's node-database migrations run against it in timestamp order, as
-- the node applies them to bee:db at boot.
local sql = require("sql")
local funcs = require("funcs")
local registry = require("registry")
local M = {}
M.NODE_DATABASE = "bee:db"

type Migration = {id: string, timestamp: string}

local function migrations(namespace: string): {Migration}
    local found = assert(registry.find({[".kind"] = "function.lua", ["meta.type"] = "migration", ["meta.target_db"] = M.NODE_DATABASE}))
    local selected: {Migration} = {}
    for _, entry in ipairs(found) do
        local id = tostring(entry.id)
        if id:sub(1, #namespace + 1) == namespace .. ":" then
            selected[#selected + 1] = {id = id, timestamp = tostring(entry.meta.timestamp)}
        end
    end
    assert(#selected > 0, "no node migrations in " .. namespace)
    table.sort(selected, function(a: Migration, b: Migration): boolean
        if a.timestamp ~= b.timestamp then return a.timestamp < b.timestamp end
        return a.id < b.id
    end)
    return selected
end

-- open applies the namespace's node migrations to database_id once and opens it.
function M.open(database_id: string, namespace: string): sql.DB
    for _, migration in ipairs(migrations(namespace)) do
        local result, call_error = funcs.call(migration.id, {target_db = M.NODE_DATABASE, database_id = database_id,
            direction = "up", id = migration.id})
        if call_error then error(migration.id .. ": " .. tostring(call_error)) end
        assert(type(result) == "table" and result.status ~= "error", migration.id .. ": " .. tostring(type(result) == "table" and result.error))
    end
    return assert(sql.get(database_id))
end

return M
