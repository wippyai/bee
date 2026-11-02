local test = require("test")
local sql = require("sql")
local funcs = require("funcs")
local json = require("json")
local DATABASE = "bee.tests.harness.profiles:names_migration_db"
local CLAUDE = "bee.drivers.claude.binding:binding"
local CODEX = "bee.drivers.codex.binding:binding"
local function profile(name: string, definition: string, binding: string, placement: {[string]: unknown}?): string
    return json.encode({schema_revision = "bee.agent-profile@3", name = name, definition_ref = definition, driver_binding_ref = binding,
        provider = {}, bee = {mcp = {}}, placement = placement})
end
local function names(db: sql.DB, feed: string): {[string]: string}
    local result: {[string]: string} = {}
    for _, row in ipairs(assert(db:query("SELECT projection_key, value_json FROM bee_sync_projections WHERE feed = ? AND tombstone = 0", {feed}))) do
        local value = json.decode(row.value_json) :: {[string]: unknown}
        result[tostring(row.projection_key)] = tostring(value.name or (value.draft :: {[string]: unknown}).name)
    end
    return result
end
local function define_tests()
    test.describe("saved profile names migration", function()
        test.it("names default profiles after their agent and placement, and gives each driver's profiles distinct names", function()
            local db = assert(sql.get(DATABASE))
            for _, statement in ipairs({
                "DROP TABLE IF EXISTS bee_sync_feeds", "DROP TABLE IF EXISTS bee_sync_projections", "DROP TABLE IF EXISTS bee_approval_grants",
                "CREATE TABLE bee_sync_feeds (owner_id TEXT, feed TEXT, head_sequence INTEGER, earliest_sequence INTEGER, PRIMARY KEY(owner_id, feed))",
                "CREATE TABLE bee_sync_projections (owner_id TEXT, feed TEXT, projection_key TEXT, value_json TEXT, tombstone INTEGER)",
                "CREATE TABLE bee_approval_grants (grant_id TEXT PRIMARY KEY, domain TEXT, owner_node TEXT, metadata_json TEXT, scope_json TEXT)",
            }) do assert(db:execute(statement)) end
            local rows = {
                {"harness.profiles:w", "a-local", profile("Claude Code", "bee.driver.claude.profiles:default_window", CLAUDE, {kind = "native", home = "private"})},
                {"harness.profiles:w", "b-docker", profile("Claude Code", "bee.driver.claude.profiles:default_window", CLAUDE, {kind = "docker", profile_ref = "bee.placement.docker.profiles:coding"})},
                {"harness.profiles:w", "c-docker", profile("claude code", "bee.driver.claude.profiles:default_window", CLAUDE, {kind = "docker", profile_ref = "bee.placement.docker.profiles:coding"})},
                {"harness.profiles:w", "d-named", profile("unsafe", "bee.driver.claude.profiles:default_window", CLAUDE)},
                {"harness.profiles:w", "e-named", profile("Unsafe ", "bee.driver.claude.profiles:default_window", CLAUDE)},
                {"harness.profiles:w", "f-codex", profile("unsafe", "bee.driver.codex.profiles:default_window", CODEX)},
                {"harness.profiles:v", "g-other", profile("Claude Code", "bee.driver.claude.profiles:default_window", CLAUDE)},
            }
            assert(db:execute("INSERT INTO bee_sync_feeds VALUES ('node', 'harness.profiles:w', 4, 1)"))
            assert(db:execute("INSERT INTO bee_sync_feeds VALUES ('node', 'harness.profiles:v', 2, 1)"))
            for _, row in ipairs(rows) do
                assert(db:execute("INSERT INTO bee_sync_projections VALUES ('node', ?, ?, ?, 0)", {row[1], row[2], row[3]}))
            end
            assert(db:execute("INSERT INTO bee_sync_projections VALUES ('node', 'harness.profiles:w', 'h-removed', NULL, 1)"))
            assert(db:execute("INSERT INTO bee_sync_projections VALUES ('node', 'harness.profiles:w', 'i-repair', ?, 0)",
                {json.encode({schema_revision = "bee.agent-profile-migration@1", draft = {name = "Claude Code", driver_binding_ref = CLAUDE}, reasons = {"repair"}})}))
            assert(db:execute("INSERT INTO bee_approval_grants VALUES ('grant-a', 'profile_choices', 'node', ?, ?)",
                {json.encode({profile_id = "a-local"}), json.encode({type = "exact", parameters = {profile_id = "a-local", configuration = json.decode(rows[1][3])}})}))
            local reply, err = funcs.call("bee.harness.migrations:profile_names", {target_db = "bee:db", database_id = DATABASE, direction = "up", id = "bee.harness.migrations:profile_names"})
            assert(not err, tostring(err))
            assert(type(reply) == "table" and reply.status ~= "error", tostring(type(reply) == "table" and reply.error))
            local w = names(db, "harness.profiles:w")
            test.eq(w["a-local"], "Claude Code · local")
            test.eq(w["b-docker"], "Claude Code · Docker")
            test.eq(w["c-docker"], "Claude Code · Docker 2")
            test.eq(w["d-named"], "unsafe")
            test.eq(w["e-named"], "Unsafe 2")
            test.eq(w["f-codex"], "unsafe")
            test.eq(w["i-repair"], "Claude Code")
            test.eq(names(db, "harness.profiles:v")["g-other"], "Claude Code · local")
            local grant = json.decode(assert(db:query("SELECT scope_json FROM bee_approval_grants"))[1].scope_json) :: {[string]: unknown}
            test.eq(((grant.parameters :: {[string]: unknown}).configuration :: {[string]: unknown}).name, "Claude Code · local")
            local feeds = assert(db:query("SELECT feed, head_sequence, earliest_sequence FROM bee_sync_feeds ORDER BY feed"))
            test.eq(feeds[1].head_sequence, 3)
            test.eq(feeds[2].head_sequence, 5)
            test.eq(feeds[2].earliest_sequence, 6)
            db:release()
        end)
    end)
end
return test.run_cases(define_tests)
