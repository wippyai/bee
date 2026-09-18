-- MIT. Opens an owned SQLite resource with the connection settings every
-- writer relies on, then checks and applies the component's ledger. The
-- component names the resource, the ledger and the migrations; nothing here
-- knows a schema.
local sql = require("sql")
local ledger = require("ledger")
local M = {}
M.BUSY_TIMEOUT_MS = 5000
type Options = {resource: string, ledger: ledger.Ledger, migrations: {ledger.Migration}}
function M.open(options: Options): (sql.DB?, string?)
    local label = options.ledger.label
    local db, acquire_err = sql.get(options.resource)
    if not db then return nil, "open " .. label .. " database: " .. tostring(acquire_err or "no reason given") end
    local db_type, type_err = db:type()
    if type_err or not db_type then
        db:release()
        return nil, "inspect " .. label .. " database"
    end
    if db_type ~= sql.type.SQLITE then
        db:release()
        return nil, label .. " database must be SQLite"
    end
    for _, pragma in ipairs({"PRAGMA journal_mode = WAL", "PRAGMA synchronous = FULL", "PRAGMA foreign_keys = ON",
        "PRAGMA busy_timeout = " .. tostring(M.BUSY_TIMEOUT_MS)}) do
        local _, pragma_err = db:execute(pragma)
        if pragma_err then
            db:release()
            return nil, "configure " .. label .. " database"
        end
    end
    local migrated, migration_err = ledger.apply(db, options.ledger, options.migrations)
    if not migrated then
        db:release()
        return nil, migration_err or (label .. " migration failed")
    end
    return db, nil
end
return M
