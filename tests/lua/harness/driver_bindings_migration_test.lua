local test = require("test")
local sql = require("sql")
local funcs = require("funcs")
local json = require("json")
local canonical = require("canonical")
local sources = require("sources")
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
        test.it("names the bee/drivers binding in carrier checkpoints, so a saved window continues under its driver", function()
            local db = assert(sql.get(DATABASE))
            assert(db:execute("CREATE TABLE bee_thread_carriers (thread_id TEXT, attempt_id TEXT, checkpoint_json TEXT, PRIMARY KEY(thread_id, attempt_id))"))
            local checkpoint = json.encode({schema_revision = "bee.carrier.checkpoint@1", binding_ref = OLD, profile_id = "window", carry = {binding_ref = OLD}})
            assert(db:execute("INSERT INTO bee_thread_carriers VALUES ('thread', 'saved', ?)", {checkpoint}))
            assert(db:execute("INSERT INTO bee_thread_carriers VALUES ('thread', 'overlay', ?)", {json.encode({schema_revision = "bee.carrier.checkpoint@1", binding_ref = "bee.driver.gemini.binding:binding"})}))
            assert(db:execute("INSERT INTO bee_thread_carriers VALUES ('thread', 'unstarted', NULL)"))
            migrate("bee.threads.migrations:driver_binding_checkpoints")
            test.eq(field(db, "SELECT checkpoint_json AS value FROM bee_thread_carriers WHERE attempt_id = 'saved'", "binding_ref"), NEW)
            test.eq(field(db, "SELECT checkpoint_json AS value FROM bee_thread_carriers WHERE attempt_id = 'saved'", "carry.binding_ref"), OLD)
            test.eq(field(db, "SELECT checkpoint_json AS value FROM bee_thread_carriers WHERE attempt_id = 'overlay'", "binding_ref"), "bee.driver.gemini.binding:binding")
            test.is_nil(assert(db:query("SELECT checkpoint_json FROM bee_thread_carriers WHERE attempt_id = 'unstarted'"))[1].checkpoint_json)
            db:release()
        end)
        test.it("names the bee/drivers API key sources in workspace credential definitions", function()
            local db = assert(sql.get(DATABASE))
            assert(db:execute([[CREATE TABLE bee_credential_definitions (workspace_id TEXT, name TEXT, provider TEXT, source_kind TEXT, source_ref TEXT,
                destination TEXT, optional INTEGER, digest TEXT, PRIMARY KEY(workspace_id, name))]]))
            local destinations = {agy = "GEMINI_API_KEY", claude = "ANTHROPIC_API_KEY", grok = "XAI_API_KEY", muse = "MUSE_API_KEY"}
            for provider, destination in pairs(destinations) do
                assert(db:execute("INSERT INTO bee_credential_definitions VALUES ('w', ?, ?, 'env_variable', ?, ?, 1, 'measured-old-source')",
                    {provider .. "_api_key", provider, "bee.driver." .. provider .. ".env:api_key", destination}))
            end
            assert(db:execute("INSERT INTO bee_credential_definitions VALUES ('w', 'claude_login', 'claude', 'fs_directory', 'bee.env:machine_login_source', '.credentials.json', 1, 'login')"))
            assert(db:execute("INSERT INTO bee_credential_definitions VALUES ('w', 'overlay_key', 'gemini', 'env_variable', 'bee.driver.gemini.env:api_key', 'GEMINI_API_KEY', 0, 'overlay')"))
            migrate("bee.credentials.migrations:driver_sources")
            local rows = assert(db:query("SELECT name, source_ref, digest FROM bee_credential_definitions ORDER BY name"))
            local stored: {[string]: {ref: string, digest: string}} = {}
            for _, row in ipairs(rows) do stored[tostring(row.name)] = {ref = tostring(row.source_ref), digest = tostring(row.digest)} end
            for provider, destination in pairs(destinations) do
                local ref = "bee.drivers." .. provider .. ".env:api_key"
                test.eq(stored[provider .. "_api_key"].ref, ref)
                local variable = assert(sources.variable(ref))
                test.eq(stored[provider .. "_api_key"].digest, assert(canonical.digest({provider = provider, source_kind = "env_variable", source_ref = ref,
                    variable = variable, projection_kind = "environment", destination = destination, optional = true})))
            end
            test.eq(stored.claude_login.ref, "bee.env:machine_login_source")
            test.eq(stored.claude_login.digest, "login")
            test.eq(stored.overlay_key.ref, "bee.driver.gemini.env:api_key")
            test.eq(stored.overlay_key.digest, "overlay")
            db:release()
        end)
    end)
end
return test.run_cases(define_tests)
