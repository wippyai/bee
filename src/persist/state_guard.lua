-- SPDX-License-Identifier: MIT
local sql = require("sql")
local registry = require("registry")
local json = require("json")
local semver = require("semver")
local bounds = require("bounds")
local writer_version = require("writer_version")
local ledger = require("ledger")
local application_databases = require("application_databases")
local process = require("process")
local M = {}
M.WRITER = "bee.persist:state_writer"
type Result = {status: string, message: string}
type Target = {id: string, known: {[string]: boolean}, namespaces: {string}, migrations: {string}}
local function refusal(folder: string, current: string, newer: string, schema: string?): string
    local written = "Bee " .. newer
    local comparison = ", newer than this Bee " .. current
    local install = "Bee " .. newer .. " or newer"
    if schema then
        written = newer == "unknown" and ("a newer Bee schema (" .. schema .. "; writer version was not recorded)")
            or (written .. " (schema " .. schema .. ")")
        comparison = ", which this Bee " .. current .. " does not support"
        install = "Bee containing schema " .. schema .. " or newer"
    end
    return 'Bee refuses to start: state in "' .. folder .. '" was written by ' .. written
        .. comparison .. ". Install " .. install .. " and open this folder again."
end
function M.check(db: sql.DB, folder: string, version: string, known: {[string]: boolean}, namespaces: {string}): string?
    local exists, table_error = ledger.table_exists(db)
    if table_error then return "Cannot inspect Bee state in " .. folder .. ": " .. tostring(table_error) end
    if not exists then return nil end
    local rows, problem = db:query("SELECT id, description FROM _migrations ORDER BY id")
    if not rows then return "Cannot inspect Bee migration ledger in " .. folder .. ": " .. tostring(problem) end
    local writer_version = "unknown"
    for _, row in ipairs(rows) do
        if row.id == M.WRITER then
            local writer = bounds.object(json.decode(tostring(row.description)))
            if not writer or type(writer.version) ~= "string" or not semver.parse(writer.version) then
                return "Cannot inspect Bee writer version in " .. folder .. ": invalid migration ledger writer"
            end
            writer_version = writer.version
            if (semver.compare(writer_version, version) or 1) > 0 then return refusal(folder, version, writer_version, nil) end
            local ids, ids_error = bounds.dense_list(writer.migrations, 10000, "Bee writer migrations")
            if not ids then return "Cannot inspect Bee schema in " .. folder .. ": " .. tostring(ids_error) end
            for _, id in ipairs(ids) do
                if type(id) ~= "string" then return "Cannot inspect Bee schema in " .. folder .. ": invalid migration ID" end
                if not known[id] then return refusal(folder, version, writer_version, id) end
            end
        end
    end
    for _, row in ipairs(rows) do
        local id = tostring(row.id)
        for _, namespace in ipairs(namespaces) do
            if id:sub(1, #namespace) == namespace and not known[id] then
                return refusal(folder, version, writer_version, id)
            end
        end
    end
    return nil
end
function M.record(db: sql.DB, version: string, build: string, migrations: {string}): (boolean?, string?)
    local initialized, init_error = ledger.init_tracking_table(db)
    if not initialized then return nil, tostring(init_error) end
    local description = assert(json.encode({version = version, build = build, migrations = migrations}))
    local tx, begin_error = db:begin()
    if not tx then return nil, tostring(begin_error) end
    local removed, remove_error = ledger.remove_migration(tx, M.WRITER)
    if not removed then tx:rollback(); return nil, tostring(remove_error) end
    local recorded, record_error = ledger.record_migration(tx, M.WRITER, description)
    if not recorded then tx:rollback(); return nil, tostring(record_error) end
    local committed, commit_error = tx:commit()
    if not committed then return nil, tostring(commit_error) end
    return true, nil
end
local function folder(db: sql.DB, database_id: string): (string?, string?)
    local kind, kind_error = db:type()
    if not kind then return nil, tostring(kind_error) end
    if kind ~= sql.type.SQLITE then return database_id, nil end
    local files, file_error = db:query("PRAGMA database_list")
    if not files then return nil, tostring(file_error) end
    local file = tostring(files[1].file)
    return file:match("^(.*)/[^/]+$") or file, nil
end

local function targets(): {Target}
    local selected: {[string]: Target} = {}
    local snapshot = assert(registry.snapshot())
    local state = assert(snapshot:state())
    for _, entry in ipairs(state.entries) do
        local id, target = tostring(entry.id), entry.meta and entry.meta.target_db
        if entry.kind == "db.sql.sqlite" and id:sub(1, #application_databases.DATABASE_PREFIX) == application_databases.DATABASE_PREFIX then
            selected[id] = selected[id] or {id = id, known = {}, namespaces = {}, migrations = {}}
        end
        if entry.meta and entry.meta.type == "migration" and type(target) == "string" then
            local item = selected[target]
            if not item then
                item = {id = target, known = {}, namespaces = {}, migrations = {}}
                selected[target] = item
            end
            item.known[id] = true
            if id:sub(1, 4) == "bee." and entry.registry and entry.registry.owner == "bee/bee" then
                item.namespaces[#item.namespaces + 1] = assert(id:match("^([^:]+:)"))
                item.migrations[#item.migrations + 1] = id
            end
        end
    end
    local result: {Target} = {}
    for _, item in pairs(selected) do
        table.sort(item.migrations)
        result[#result + 1] = item
    end
    table.sort(result, function(a: Target, b: Target): boolean return a.id < b.id end)
    return result
end
function M.prepare(database_id: string): (boolean?, string?)
    local db, open_error = sql.get(database_id)
    if not db then return nil, tostring(open_error) end
    local location, location_error = folder(db, database_id)
    if not location then db:release(); return nil, location_error end
    local exists, table_error = ledger.table_exists(db)
    if table_error then db:release(); return nil, tostring(table_error) end
    local ids: {string} = {}
    local known: {[string]: boolean} = {}
    if exists then
        local rows, row_error = db:query("SELECT description FROM _migrations WHERE id = 'bee.persist:state_writer'")
        if not rows then db:release(); return nil, tostring(row_error) end
        if #rows > 0 then
            local writer = bounds.object(json.decode(tostring(rows[1].description)))
            local migrations = writer and bounds.dense_list(writer.migrations, 10000, "Bee writer migrations")
            for _, id in ipairs(migrations or {}) do
                if type(id) ~= "string" then db:release(); return nil, "invalid Bee writer migration ID" end
                ids[#ids + 1] = id
                known[id] = true
            end
        end
    end
    local problem = M.check(db, location, writer_version.version, known, {})
    if problem then db:release(); return nil, problem end
    local recorded, record_error = M.record(db, writer_version.version, writer_version.build, ids)
    db:release()
    return recorded, record_error
end
local function inspect(selected: {Target}, version: string): string?
    for _, target in ipairs(selected) do
        local db, open_error = sql.get(target.id)
        if not db then return "Cannot inspect Bee database " .. target.id .. ": " .. tostring(open_error) end
        local location, location_error = folder(db, target.id)
        if not location then db:release(); return tostring(location_error) end
        local problem = M.check(db, location, version, target.known, target.namespaces)
        db:release()
        if problem then return problem end
    end
    return nil
end
function M.inspect(): string?
    return inspect(targets(), writer_version.version)
end
function M.main()
    local problem = M.inspect()
    if problem then
        local reporter, report_error = process.spawn("bee.persist:state_refusal", "bee:terminal", problem)
        assert(reporter, tostring(report_error))
        error("Bee state version is incompatible")
    end
end
function M.run(): Result
    local version, build = writer_version.version, writer_version.build
    assert(type(version) == "string" and semver.parse(version), "Bee binary version is unavailable")
    assert(type(build) == "string", "Bee binary build is unavailable")
    local selected = targets()
    local problem = inspect(selected, version)
    if problem then return {status = "error", message = problem} end
    for _, target in ipairs(selected) do
        local db = assert(sql.get(target.id))
        local recorded, problem = M.record(db, version, build, target.migrations)
        db:release()
        if not recorded then return {status = "error", message = "Cannot record Bee state version for " .. target.id .. ": " .. tostring(problem)} end
    end
    return {status = "success", message = "Bee state version is compatible"}
end
return M
