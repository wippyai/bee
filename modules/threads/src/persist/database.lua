-- MIT. The threads store: the linked SQLite resource opened through the
-- shared persist helper against the threads ledger.
local sql = require("sql")
local persist = require("persist")
local migrations = require("migrations")
local M = {}
M.LEDGER = {table = "bee_thread_schema_migrations", label = "thread"}
-- Opens the resource at the given ledger length; production passes every
-- migration, tests open earlier revisions to prove upgrades.
function M.open_at(resource: string, count: integer): (sql.DB?, string?)
    return persist.open({resource = resource, ledger = M.LEDGER, migrations = migrations.prefix(count)})
end
function M.open(resource: string): (sql.DB?, string?)
    return M.open_at(resource, #migrations.all())
end
return M
