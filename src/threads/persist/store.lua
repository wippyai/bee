-- MIT. Compatibility surface of the journal: the store handle the legacy
-- methods open per call.
local sql = require("sql")
local database = require("database")
local legacy = require("legacy")
type Store = {
    db: sql.DB,
    closed: boolean,
    claim: (Store, string, string, string) -> (boolean?, string?),
    append: (Store, string, string, string, string, string, string) -> (integer?, string?),
    read: (Store, string, string, integer) -> ({legacy.Event}?, string?),
    close: (Store) -> (boolean, string?),
}
local M = {}
local function claim(store: Store, actor: string, thread: string, run: string): (boolean?, string?)
    if store.closed then return nil, "thread store is closed" end
    return legacy.claim(store.db, actor, thread, run)
end
local function append(store: Store, actor: string, thread: string, run: string, key: string, kind: string, body: string): (integer?, string?)
    if store.closed then return nil, "thread store is closed" end
    return legacy.append(store.db, actor, thread, run, key, kind, body)
end
local function read(store: Store, actor: string, thread: string, after: integer): ({legacy.Event}?, string?)
    if store.closed then return nil, "thread store is closed" end
    return legacy.read(store.db, actor, thread, after)
end
local function close(store: Store): (boolean, string?)
    if store.closed then return true, nil end
    store.closed = true
    local released, release_err = store.db:release()
    if release_err or released ~= true then return false, "close thread database" end
    return true, nil
end
-- resource names the SQL entry the host linked for this module.
function M.open(resource: string): (Store?, string?)
    local db, open_err = database.open(resource)
    if not db then return nil, open_err end
    return {db = db, closed = false, claim = claim, append = append, read = read, close = close}, nil
end
return M
