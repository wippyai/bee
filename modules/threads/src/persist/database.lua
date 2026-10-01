-- MIT. The threads store: the linked SQLite resource opened through the
-- shared persist helper against the threads ledger.
local sql = require("sql")
local persist = require("persist")
local migrations = require("migrations")
local definition_migration = require("definition_migration")
local M = {}
M.LEDGER = {table = "bee_thread_schema_migrations", label = "thread"}
-- Opens the resource at the given ledger length; production passes every
-- migration, tests open earlier revisions to prove upgrades.
function M.open_at(resource: string, count: integer): (sql.DB?, string?)
    local db, open_error = persist.open({resource = resource, ledger = M.LEDGER, migrations = migrations.prefix(count)})
    if not db then return nil, open_error end
    if count >= 28 then
        local migrated, migration_error = definition_migration.apply(db)
        if not migrated then db:release(); return nil, migration_error end
    end
    return db, nil
end
function M.open(resource: string): (sql.DB?, string?)
    return M.open_at(resource, #migrations.all())
end
return M
