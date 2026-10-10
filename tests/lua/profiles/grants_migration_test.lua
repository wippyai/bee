local test = require("test")
local sql = require("sql")
local hash = require("hash")
local json = require("json")
local funcs = require("funcs")
local schema = require("schema")
local grants = require("grants")
local authority = require("authority")
local bounds = require("bounds")
local DATABASE = "bee.harness.profiles:grants_migration_db"
local function define_tests()
    test.describe("Saved profile Grant migration",function()
        test.it("preserves exact legacy choices and attributes retained actors, failing closed on orphaned workspaces",function()
            local db = schema.open(DATABASE,"bee.approvals.migrations")
            db:release(); db = schema.open(DATABASE,"bee.sync.migrations")
            assert(db:execute("CREATE TABLE bee_node_workspaces(id TEXT PRIMARY KEY)"))
            assert(db:execute("INSERT INTO bee_node_workspaces VALUES ('workspace')"))
            local feed = "harness.profiles:" .. assert(hash.sha256("workspace"))
            local orphan = "harness.profiles:" .. assert(hash.sha256("deleted-workspace"))
            for _, name in ipairs({feed,orphan}) do assert(db:execute("INSERT INTO bee_sync_feeds VALUES ('node',?,1,1,128,1024)",{name})) end
            local configuration = {schema_revision = "bee.agent-profile@3",name = "Legacy",definition_ref = "bee.driver.codex.profiles:research_batch",driver_binding_ref = "bee.driver.codex.binding:binding",provider = {},bee = {mcp = {}}}
            for _, item in ipairs({{feed = feed,id = "old"},{feed = feed,id = "retained-away"},{feed = orphan,id = "orphan"}}) do
                assert(db:execute("INSERT INTO bee_sync_projections VALUES ('node',?,?,2,?,0,1,'2026-10-01T00:00:00Z')",{item.feed,item.id,json.encode(configuration)}))
            end
            assert(db:execute("INSERT INTO bee_sync_events VALUES ('node',?,1,'event','harness.profile.changed',?,'old',2,0,'2026-10-01T00:00:00Z')",{feed,json.encode({workspace_id = "workspace",actor_id = "original-person"})}))
            local id = "bee.harness.migrations:profile_grants"
            local result, err = funcs.call(id,{target_db = "bee:db",database_id = DATABASE,direction = "up",id = id})
            assert(not err,tostring(err)); assert(assert(bounds.object(result)).status ~= "error",json.encode(result))
            local first = assert(grants.read(db,authority.id("node","workspace","old",2)))
            test.eq(first.granted_by,"original-person")
            test.eq(first.provenance.kind,"legacy")
            test.eq(json.encode(assert(bounds.object(first.scope.parameters)).configuration),(json.encode(configuration)))
            test.eq(first.created_at,"2026-10-01T00:00:00.000Z")
            local missing_actor = assert(grants.read(db,authority.id("node","workspace","retained-away",2)))
            test.eq(missing_actor.granted_by,"legacy:node")
            local unresolved = assert(grants.read(db,authority.id("node","legacy:" .. orphan,"orphan",2)))
            test.eq(unresolved.state,"revoked")
            test.eq(#assert(db:query("SELECT * FROM bee_sync_projections")),3)
            test.eq(#assert(db:query("SELECT * FROM bee_approval_grants")),3)
            db:release()
        end)
        test.it("migrates legacy selections atomically without changing revisions, delegation or revocation", function()
            local db = schema.open(DATABASE, "bee.approvals.migrations")
            local feed = "harness.profiles:" .. assert(hash.sha256("consent-workspace"))
            assert(db:execute("INSERT INTO bee_sync_feeds VALUES ('node',?,1,1,128,1024)", {feed}))
            local parent = assert(grants.read(db, authority.id("node", "workspace", "old", 2)))
            for _, name in ipairs({"absent", "empty", "delegated", "revoked", "requestable"}) do
                local configuration: {[string]: unknown} = {schema_revision = "bee.agent-profile@3", name = name,
                    definition_ref = "bee.driver.codex.profiles:research_batch", driver_binding_ref = "bee.driver.codex.binding:binding",
                    provider = {}, bee = {mcp = {{tool = "app_tools", scope = {}}}}}
                if name == "empty" then configuration.active_traits, configuration.requestable = {}, {} end
                if name == "requestable" then configuration.requestable = {"bee.app:tools"} end
                assert(db:execute("INSERT INTO bee_sync_projections VALUES ('node',?,?,2,?,0,1,'2026-10-01T00:00:00Z')", {feed, name, json.encode(configuration)}))
                local record = assert(authority.save(db, "node", "consent-workspace", name, 2, configuration, "person", true,
                    "2026-10-01T00:00:00.000Z", name == "delegated" and parent or nil))
                if name == "revoked" then assert(db:execute("UPDATE bee_approval_grants SET state = 'revoked' WHERE grant_id = ?", {record.grant_id})) end
            end
            local id = "bee.harness.migrations:profile_consent_traits"
            for _ = 1, 2 do
                local result, err = funcs.call(id, {target_db = "bee:db", database_id = DATABASE, direction = "up", id = id})
                assert(not err, tostring(err)); assert(assert(bounds.object(result)).status ~= "error", json.encode(result))
                for _, row in ipairs(assert(db:query("SELECT * FROM bee_sync_projections WHERE feed = ?", {feed}))) do
                    local record = assert(grants.read(db, authority.id("node", "consent-workspace", row.projection_key, 2)))
                    local profile = assert(bounds.object(json.decode(row.value_json)))
                    local configuration = assert(bounds.object(assert(bounds.object(record.scope.parameters)).configuration))
                    test.eq(json.encode(profile), (json.encode(configuration)))
                    test.eq(row.revision, 2)
                    if row.projection_key == "requestable" then
                        test.is_nil(profile.active_traits)
                        test.eq(record.provenance.kind, "legacy")
                    else
                        test.eq(assert(bounds.ids(profile.active_traits, true))[1], "bee.app:tools")
                        test.eq(record.provenance.kind, row.projection_key == "delegated" and "delegated" or "consent")
                        test.eq(record.state, row.projection_key == "revoked" and "revoked" or "active")
                    end
                end
                local heads = assert(db:query("SELECT head_sequence,earliest_sequence FROM bee_sync_feeds WHERE feed = ?", {feed}))
                test.eq(heads[1].head_sequence, 2)
                test.eq(heads[1].earliest_sequence, 3)
            end
            db:release()
        end)
    end)
end
return test.run_cases(define_tests)
