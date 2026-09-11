-- MIT. Opens the linked SQLite resource with the sync schema checked before
-- an owner uses it.
local sql = require("sql")
local persist = require("persist")
local migrations = require("migrations")
local M = {}
M.LEDGER = {table = "bee_sync_schema_migrations", label = "sync"}
function M.open(resource: string): (sql.DB?, string?)
    return persist.open({resource = resource, ledger = M.LEDGER, migrations = migrations.all()})
end
return M
