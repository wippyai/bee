-- MIT. Opens an owned SQLite resource with the connection settings every
-- writer relies on, then checks and applies the component's ledger. The
-- component names the resource, the ledger and the migrations; nothing here
-- knows a schema.
local sql = require("sql")
local sqlerrors = require("sqlerrors")
local ledger = require("ledger")
local M = {}
M.BUSY_TIMEOUT_MS = 5000
type Options = {resource: string, ledger: ledger.Ledger, migrations: {ledger.Migration}}
local function close(db: sql.DB, message: string): string
    local released, err = db:release()
    if released ~= true or err then return message .. "; release database: " .. sqlerrors.describe(err or "no reason given") end
    return message
end
function M.open(options: Options): (sql.DB?, string?)
    local label = options.ledger.label
    local db, acquire_err = sql.get(options.resource)
    if not db then return nil, "open " .. label .. " database: " .. sqlerrors.describe(acquire_err or "no reason given") end
    local db_type, type_err = db:type()
    if type_err or not db_type then
        return nil, close(db, "inspect " .. label .. " database: " .. sqlerrors.describe(type_err or "no reason given"))
    end
    if db_type ~= sql.type.SQLITE then
        return nil, close(db, label .. " database must be SQLite")
    end
    for _, pragma in ipairs({"PRAGMA journal_mode = WAL", "PRAGMA synchronous = FULL", "PRAGMA foreign_keys = ON",
        "PRAGMA busy_timeout = " .. tostring(M.BUSY_TIMEOUT_MS)}) do
        local _, pragma_err = db:execute(pragma)
        if pragma_err then
            return nil, close(db, "configure " .. label .. " database (" .. pragma .. "): " .. sqlerrors.describe(pragma_err))
        end
    end
    local migrated, migration_err = ledger.apply(db, options.ledger, options.migrations)
    if not migrated then
        return nil, close(db, migration_err or (label .. " migration failed"))
    end
    return db, nil
end
return M
