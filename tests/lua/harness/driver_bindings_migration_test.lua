local test = require("test")
local sql = require("sql")
local funcs = require("funcs")
local json = require("json")
local DATABASE = "bee.tests.harness:driver_bindings_migration_db"
local OLD = "bee.driver.claude.binding:binding"
local NEW = "bee.drivers.claude.binding:binding"
local function migrate(id: string)
    local reply, err = funcs.call(id, {target_db = "bee:db", database_id = DATABASE, direction = "up", id = id})
    assert(not err, tostring(err))
    assert(type(reply) == "table" and reply.status ~= "error", tostring(type(reply) == "table" and reply.error))
end
local function field(db: sql.DB, query: string, path: string): unknown
    local rows = assert(db:query(query))
    test.eq(#rows, 1)
    local value: unknown = json.decode(rows[1].value)
    for key in path:gmatch("[^.]+") do value = (value :: {[string]: unknown})[key] end
    return value
end
local function define_tests()
    test.describe("built-in driver binding migration", function()
        test.it("names the bee/drivers bindings in saved profiles, profile grants and session routes", function()
            local db = assert(sql.get(DATABASE))
            for _, statement in ipairs({
                "CREATE TABLE bee_sync_feeds (owner_id TEXT, feed TEXT, head_sequence INTEGER, earliest_sequence INTEGER, PRIMARY KEY(owner_id, feed))",
                "CREATE TABLE bee_sync_projections (owner_id TEXT, feed TEXT, projection_key TEXT, value_json TEXT, tombstone INTEGER)",
                "CREATE TABLE bee_approval_grants (grant_id TEXT PRIMARY KEY, scope_json TEXT)",
                "CREATE TABLE bee_sessions (session_ref TEXT PRIMARY KEY, route_json TEXT)",
            }) do assert(db:execute(statement)) end
            local profile = json.encode({schema_revision = "bee.agent-profile@3", definition_ref = "bee.driver.claude.profiles:default_window", driver_binding_ref = OLD})
            local diagnostic = json.encode({schema_revision = "bee.agent-profile-migration@1", draft = {driver_binding_ref = OLD}, source = {driver_binding_ref = OLD}})
            local other = json.encode({schema_revision = "bee.agent-profile@3", driver_binding_ref = "bee.driver.gemini.binding:binding"})
            assert(db:execute("INSERT INTO bee_sync_feeds VALUES ('node', 'harness.profiles:w', 4, 1)"))
            assert(db:execute("INSERT INTO bee_sync_feeds VALUES ('node', 'harness.profiles:v', 7, 1)"))
            assert(db:execute("INSERT INTO bee_sync_projections VALUES ('node', 'harness.profiles:w', 'saved', ?, 0)", {profile}))
            assert(db:execute("INSERT INTO bee_sync_projections VALUES ('node', 'harness.profiles:w', 'diagnostic', ?, 0)", {diagnostic}))
            assert(db:execute("INSERT INTO bee_sync_projections VALUES ('node', 'harness.profiles:v', 'overlay', ?, 0)", {other}))
            assert(db:execute("INSERT INTO bee_approval_grants VALUES ('grant', ?)", {json.encode({type = "exact", parameters = {configuration = {driver_binding_ref = OLD}}})}))
            assert(db:execute("INSERT INTO bee_sessions VALUES ('session', ?)", {json.encode({definition = "bee.driver.claude.profiles:default_window", driver_binding_ref = OLD})}))
            migrate("bee.harness.migrations:driver_bindings")
            migrate("bee.threads.migrations:driver_bindings")
            test.eq(field(db, "SELECT value_json AS value FROM bee_sync_projections WHERE projection_key = 'saved'", "driver_binding_ref"), NEW)
            test.eq(field(db, "SELECT value_json AS value FROM bee_sync_projections WHERE projection_key = 'diagnostic'", "draft.driver_binding_ref"), NEW)
            test.eq(field(db, "SELECT value_json AS value FROM bee_sync_projections WHERE projection_key = 'diagnostic'", "source.driver_binding_ref"), OLD)
            test.eq(field(db, "SELECT value_json AS value FROM bee_sync_projections WHERE projection_key = 'overlay'", "driver_binding_ref"), "bee.driver.gemini.binding:binding")
            test.eq(field(db, "SELECT scope_json AS value FROM bee_approval_grants", "parameters.configuration.driver_binding_ref"), NEW)
            test.eq(field(db, "SELECT route_json AS value FROM bee_sessions", "driver_binding_ref"), NEW)
            local feeds = assert(db:query("SELECT feed, head_sequence, earliest_sequence FROM bee_sync_feeds ORDER BY feed"))
            test.eq(feeds[1].head_sequence, 7)
            test.eq(feeds[2].head_sequence, 5)
            test.eq(feeds[2].earliest_sequence, 6)
            db:release()
        end)
    end)
end
return test.run_cases(define_tests)
