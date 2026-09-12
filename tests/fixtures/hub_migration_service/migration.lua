-- MIT. Transactional package fixture; the public DSL has separate compatibility acceptance.
local sql = require("sql")
local function run(options)
    local db = assert(sql.get(options.database_id))
    local tx = assert(db:begin())
    assert(tx:execute("CREATE TABLE IF NOT EXISTS _migrations (id TEXT PRIMARY KEY, applied_at TEXT NOT NULL)"))
    assert(tx:execute("CREATE TABLE fixture_payload (value TEXT)"))
    assert(tx:execute("INSERT INTO fixture_payload VALUES ('committed')"))
    assert(tx:execute("INSERT INTO _migrations (id, applied_at) VALUES ($1, $2)", {options.id, "2026-09-12T12:00:00Z"}))
    assert(tx:commit())
    db:release()
    return {id = options.id, status = "applied"}
end
return {run = run}
