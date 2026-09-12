-- MIT. Execute the standard migration function contract under host-selected
-- permissions. Package functions own their DSL and ledger transactions.
local sql = require("sql")
local funcs = require("funcs")
local security = require("security")
local migrations = require("migrations")
local M = {}
type Applied = {id: string, group: integer}

function M.allowed(entries: {migrations.Entry}): (boolean, string?)
    for _, entry in ipairs(entries) do
        local target = entry.meta.target_db
        if type(target) ~= "string" or not security.can("db.get", target) then
            return false, "host database grant required for migration " .. entry.id
        end
        if not security.can("funcs.call", entry.id) then
            return false, "host function grant required for migration " .. entry.id
        end
    end
    return true, nil
end

-- Query only the selected IDs. Checking an absent ledger never creates it.
local function read_applied(target: string, ids: {string}): ({Applied}?, string?)
    local db, open_error = sql.get(target)
    if not db then return nil, tostring(open_error) end
    local kind, type_error = db:type()
    if type_error then db:release(); return nil, tostring(type_error) end
    local exists: string
    if kind == sql.type.SQLITE then
        exists = "SELECT COUNT(*) AS count FROM sqlite_master WHERE type = 'table' AND name = '_migrations'"
    elseif kind == sql.type.POSTGRES then
        exists = "SELECT COUNT(*) AS count FROM information_schema.tables WHERE table_schema = current_schema() AND table_name = '_migrations'"
    elseif kind == sql.type.MYSQL then
        exists = "SELECT COUNT(*) AS count FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = '_migrations'"
    else
        db:release(); return nil, "unsupported migration ledger database"
    end
    local tables, tables_error = db:query(exists)
    if not tables then db:release(); return nil, tostring(tables_error) end
    local row = tables[1]
    local count = row and row.count
    if (type(count) ~= "number" and type(count) ~= "string") or tonumber(count) == nil then
        db:release(); return nil, "invalid migration ledger existence result"
    end
    if tonumber(count) == 0 then db:release(); return {}, nil end
    local parameters: {unknown} = {}
    local placeholders: {string} = {}
    for index, id in ipairs(ids) do
        parameters[index] = id
        placeholders[index] = kind == sql.type.POSTGRES and "$" .. tostring(index) or "?"
    end
    if #ids == 0 then db:release(); return {}, nil end
    local rows, query_error = db:query("SELECT id, applied_at FROM _migrations WHERE id IN ("
        .. table.concat(placeholders, ",") .. ") ORDER BY applied_at DESC", parameters)
    db:release()
    if not rows then return nil, tostring(query_error) end
    local result: {Applied} = {}
    local previous: string? = nil
    local group = 0
    for _, item in ipairs(rows) do
        if type(item.id) ~= "string" or item.applied_at == nil then return nil, "invalid migration ledger row" end
        local stamp = tostring(item.applied_at)
        if stamp ~= previous then group = group + 1; previous = stamp end
        result[#result + 1] = {id = item.id, group = group}
    end
    return result, nil
end

function M.source(entries: {migrations.Entry}): migrations.Source
    local by_id: {[string]: migrations.Entry} = {}
    for _, entry in ipairs(entries) do by_id[entry.id] = entry end
    local function selected(target: string, raw: unknown): {string}
        if type(raw) ~= "table" or type(raw.allowed_ids) ~= "table" then error("migration IDs required") end
        local ids: {string} = {}
        local seen: {[string]: boolean} = {}
        for _, id in ipairs(raw.allowed_ids :: {unknown}) do
            if type(id) ~= "string" then error("invalid migration ID") end
            local entry = by_id[id]
            if not entry or entry.meta.target_db ~= target or seen[id] then error("migration is outside the captured database selection") end
            seen[id] = true
            ids[#ids + 1] = id
        end
        if #ids == 0 or #ids > migrations.MAX_MIGRATIONS then error("invalid migration selection size") end
        return ids
    end
    local function execute(target: string, id: string, direction: string): unknown
        local entry = by_id[id]
        if not entry or entry.meta.target_db ~= target then error("migration is outside the captured database selection") end
        local allowed, grant_error = M.allowed({entry})
        if not allowed then error(grant_error or "migration grant denied") end
        local result, call_error = funcs.call(id, {database_id = target, direction = direction, id = id})
        if call_error then error(tostring(call_error)) end
        if type(result) ~= "table" or type(result.status) ~= "string" then error("invalid migration function result") end
        if result.status == "error" then error(type(result.error) == "string" and result.error or "migration function failed") end
        -- The standard DSL wraps its per-migration result; standalone
        -- migration functions may return the same result directly.
        local value: unknown = result
        if type(result.migrations) == "table" and #result.migrations > 0 then value = result.migrations[1] end
        if type(value) ~= "table" or type(value.status) ~= "string" then error("invalid migration result row") end
        if value.status == "error" then error(type(value.error) == "string" and value.error or "migration function failed") end
        return {id = id, status = value.status}
    end
    return {
        entries = entries,
        is_applied = function(target: string, id: string): (boolean?, string?)
            local entry = by_id[id]
            if not entry or entry.meta.target_db ~= target then return nil, "migration is outside the captured database selection" end
            local rows, problem = read_applied(target, {id})
            if not rows then return nil, problem end
            return #rows == 1, nil
        end,
        runner = {setup = function(target: string): (migrations.DatabaseRunner?, string?)
            return {
                run_next = function(_: migrations.DatabaseRunner, options: {[string]: unknown}): migrations.RunnerResult
                    local ids = selected(target, options)
                    if #ids ~= 1 then error("one migration ID required") end
                    return {migrations = {execute(target, ids[1], "up")}}
                end,
                rollback = function(_: migrations.DatabaseRunner, options: {[string]: unknown}): migrations.RunnerResult
                    local ids = selected(target, options)
                    if options.count ~= #ids then error("rollback count differs from selected IDs") end
                    local applied, problem = read_applied(target, ids)
                    if not applied then error(problem or "read migration ledger") end
                    table.sort(applied, function(a: Applied, b: Applied): boolean
                        if a.group ~= b.group then return a.group < b.group end
                        local left, right = by_id[a.id], by_id[b.id]
                        local at = left and left.meta.timestamp or ""
                        local bt = right and right.meta.timestamp or ""
                        if type(at) ~= "string" or type(bt) ~= "string" then error("invalid migration timestamp") end
                        if at ~= bt then return at > bt end
                        return a.id > b.id
                    end)
                    local results: {unknown} = {}
                    for _, item in ipairs(applied) do
                        local ok, value = pcall(function() return execute(target, item.id, "down") end)
                        if not ok then return {migrations = results, error = "rollback migration " .. item.id .. ": " .. tostring(value)} end
                        results[#results + 1] = value
                    end
                    return {migrations = results}
                end,
            }, nil
        end},
    }
end

return M
