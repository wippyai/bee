-- SPDX-License-Identifier: MIT
local sql = require("sql")
local registry = require("registry")
local json = require("json")
local bounds = require("bounds")
local writer_version = require("writer_version")
local ledger = require("ledger")
local process = require("process")
local activations = require("activations")
local system = require("system")
local M = {}
M.WRITER = "bee.persist:state_writer"
type Result = {status: string, message: string}
type Target = {id: string, known: {[string]: boolean}, migrations: {string}}
local function refusal(folder: string, current: string, writer: string, schema: string): string
    local written = writer == "unknown" and ("a newer Bee schema (" .. schema .. "; writer version was not recorded)")
        or ("Bee " .. writer .. " (schema " .. schema .. ")")
    return 'Bee refuses to start: state in "' .. folder .. '" was written by ' .. written
        .. ", which this Bee " .. current .. " does not support. Install Bee containing schema "
        .. schema .. " or newer and open this folder again."
end
function M.check(db: sql.DB, folder: string, version: string, known: {[string]: boolean}): string?
    local exists, table_error = ledger.table_exists(db)
    if table_error then return "Cannot inspect Bee state in " .. folder .. ": " .. tostring(table_error) end
    if not exists then return nil end
    local rows, problem = db:query("SELECT id, description FROM _migrations ORDER BY id")
    if not rows then return "Cannot inspect Bee migration ledger in " .. folder .. ": " .. tostring(problem) end
    local label = "unknown"
    for _, row in ipairs(rows) do
        if row.id == M.WRITER then
            local writer = bounds.object(json.decode(tostring(row.description)))
            if not writer or type(writer.version) ~= "string" then
                return "Cannot inspect Bee writer version in " .. folder .. ": invalid migration ledger writer"
            end
            label = writer.version
            local revision = writer.format_revision == nil and 1 or writer.format_revision
            if type(revision) ~= "number" or revision < 1 or revision % 1 ~= 0 then
                return "Cannot inspect Bee schema in " .. folder .. ": invalid state format revision"
            end
            if revision > writer_version.format_revision then
                return refusal(folder, version, label, "format revision " .. tostring(revision))
            end
        end
    end
    for _, row in ipairs(rows) do
        local id = tostring(row.id)
        if id ~= M.WRITER and not known[id] then return refusal(folder, version, label, id) end
    end
    return nil
end
function M.record(db: sql.DB, version: string, build: string, migrations: {string}): (boolean?, string?)
    local initialized, init_error = ledger.init_tracking_table(db)
    if not initialized then return nil, tostring(init_error) end
    local description = assert(json.encode({version = version, build = build, migrations = migrations, format_revision = writer_version.format_revision}))
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
    local databases: {[string]: boolean} = {}
    for _, entry in ipairs(state.entries) do
        if entry.kind == "db.sql.sqlite" then databases[entry.id] = true end
    end
    for _, entry in ipairs(state.entries) do
        if entry.kind == "registry.entry" and entry.meta and entry.meta.type == "bee.governance-capability-grants@1" then
            local data = assert(bounds.object(entry.data),"admitted capability grant data is invalid")
            local declared = assert(bounds.dense_list(data.databases or {},8,"admitted databases"))
            for _, raw in ipairs(declared) do
                local database = assert(bounds.object(raw),"admitted database declaration is invalid")
                local id = assert(bounds.id(database.id),"admitted database identity is invalid")
                assert(database.kind == "db.sql.sqlite" and databases[id],"admitted database is unavailable: " .. id)
                selected[id] = selected[id] or {id = id,known = {},migrations = {}}
            end
        end
    end
    for _, entry in ipairs(state.entries) do
        local id, target = tostring(entry.id), entry.meta and entry.meta.target_db
        if entry.meta and entry.meta.type == "migration" and type(target) == "string" then
            local item = selected[target]
            if not item then
                item = {id = target, known = {}, migrations = {}}
                selected[target] = item
            end
            item.known[id] = true
            item.migrations[#item.migrations + 1] = id
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
local function application_schemas(targets: {Target}): string?
    local selected: {[string]: Target} = {}
    for _, target in ipairs(targets) do selected[target.id] = target end
    local db, open_error = sql.get("bee:db")
    if not db then return tostring(open_error) end
    local tables, table_error = db:query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'bee_governance_applied_migrations'")
    db:release()
    if not tables then return tostring(table_error) end
    if #tables > 0 then
        local listed = activations.applied_databases("bee:db", assert(system.node.id()))
        local value = listed.ok and bounds.object(listed.value) or nil
        local rows = value and bounds.dense_list(value.databases, 1024, "applied migration databases") or nil
        if not rows then return listed.message or "applied migration databases are malformed" end
        for _, raw in ipairs(rows) do
            local row = assert(bounds.object(raw))
            local id = assert(bounds.id(row.database_id))
            local item = selected[id]
            if item and id ~= "bee:db" then
                local ids = assert(bounds.dense_list(row.migrations, 10000, "application migrations"))
                for _, migration in ipairs(ids) do
                    local migration_id = assert(bounds.id(migration))
                    if not item.known[migration_id] then item.migrations[#item.migrations + 1] = migration_id end
                    item.known[migration_id] = true
                end
            end
        end
    end
    return nil
end
function M.prepare(database_id: string, migrations: {string}?): (boolean?, string?)
    local db, open_error = sql.get(database_id)
    if not db then return nil, tostring(open_error) end
    local location, location_error = folder(db, database_id)
    if not location then db:release(); return nil, location_error end
    local ids: {string} = {}
    local known: {[string]: boolean} = {}
    local selected = targets()
    local schema_error = application_schemas(selected)
    if schema_error then db:release(); return nil, schema_error end
    for _, target in ipairs(selected) do
        if target.id == database_id then
            for _, id in ipairs(target.migrations) do known[id] = true; ids[#ids + 1] = id end
        end
    end
    for _, id in ipairs(migrations or {}) do
        if not known[id] then ids[#ids + 1] = id end
        known[id] = true
    end
    table.sort(ids)
    local problem = M.check(db, location, writer_version.version, known)
    if problem then db:release(); return nil, problem end
    local recorded, record_error = M.record(db, writer_version.version, writer_version.build, ids)
    db:release()
    return recorded, record_error
end
local function inspect_database(target: Target, version: string): string?
    local db, open_error = sql.get(target.id)
    if not db then return "Cannot inspect Bee database " .. target.id .. ": " .. tostring(open_error) end
    local location, location_error = folder(db, target.id)
    if not location then db:release(); return tostring(location_error) end
    local problem = M.check(db, location, version, target.known)
    db:release()
    return problem
end
local function inspect(selected: {Target}, version: string): string?
    for _, target in ipairs(selected) do
        if target.id == "bee:db" then
            local problem = inspect_database(target, version)
            if problem then return problem end
        end
    end
    local schema_error = application_schemas(selected)
    if schema_error then return schema_error end
    for _, target in ipairs(selected) do
        if target.id ~= "bee:db" then
            local problem = inspect_database(target, version)
            if problem then return problem end
        end
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
    assert(type(version) == "string", "Bee binary version is unavailable")
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
