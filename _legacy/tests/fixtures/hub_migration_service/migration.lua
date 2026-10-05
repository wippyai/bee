-- MIT. Transactional package fixture; the public DSL has separate compatibility acceptance.
local sql = require("sql")
local security = require("security")
local function run(options)
    for _, check in ipairs({
        {"registry.apply", "*"}, {"registry.apply_version", "*"},
        {"registry.create.ns.dependency", "bee.hub.deps:probe"},
        {"registry.update.registry.entry", "bee.hub.operations:probe"},
        {"bee.hub.execute", "bee.hub.binding:backend"}, {"process.spawn", "bee.hub.service:worker"}, {"process.host", "bee:workers"},
        {"process.registry.register", "bee.hub.publisher"},
        {"process.send", "probe"}, {"funcs.security", "security"},
        {"security.scope.create", "without"},
    }) do
        assert(not security.can(check[1], check[2]), "migration inherited Hub authority: " .. check[1])
    end
    local db = assert(sql.get(options.database_id))
    local tx = assert(db:begin())
    assert(tx:execute("CREATE TABLE IF NOT EXISTS _migrations (id TEXT PRIMARY KEY, applied_at TEXT NOT NULL)"))
    if options.direction == "down" then
        assert(tx:execute("DROP TABLE fixture_payload"))
        assert(tx:execute("DELETE FROM _migrations WHERE id = $1", {options.id}))
        assert(tx:commit())
        db:release()
        return {id = options.id, status = "reverted"}
    end
    assert(tx:execute("CREATE TABLE fixture_payload (value TEXT)"))
    assert(tx:execute("INSERT INTO fixture_payload VALUES ('committed')"))
    assert(tx:execute("INSERT INTO _migrations (id, applied_at) VALUES ($1, $2)", {options.id, "2026-09-12T12:00:00Z"}))
    assert(tx:commit())
    db:release()
    return {id = options.id, status = "applied"}
end
return {run = run}
