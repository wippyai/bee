-- MIT. Folded gateway tools: a saved selection, binding or grant that names
-- a tool another tool carries moves to that carrier, restricted to the
-- operations it named, and the old name is retired.
local test = require("test")
local sql = require("sql")
local json = require("json")
local funcs = require("funcs")
local bounds = require("bounds")
local folds = require("folds")
local mcp = require("mcp")
local surface = require("surface")
local access = require("access")
local scope = require("scope")
local canonical = require("canonical")
type Object = {[string]: unknown}
local DATABASE = "bee.tests.gateway:tool_folds_db"

local function migrate(id: string)
    local reply, err = funcs.call(id, {target_db = "bee:db", database_id = DATABASE, direction = "up", id = id})
    assert(not err, tostring(err))
    assert(type(reply) == "table" and reply.status ~= "error", tostring(type(reply) == "table" and reply.error))
end

local function decoded(db: sql.DB, statement: string, params: {unknown}?): Object
    local rows = assert(db:query(statement, params or {}))
    return assert(bounds.object(json.decode(tostring(rows[1].value))))
end

local function tools(entries: unknown): {string}
    local names: {string} = {}
    for _, raw in ipairs(assert(bounds.array(entries, 64))) do names[#names + 1] = tostring(assert(bounds.object(raw)).tool) end
    return names
end

local SELECTION = {{tool = "session_open", scope = {}}, {tool = "session_close", scope = {}}, {tool = "session_remove", scope = {}},
    {tool = "session_rename", scope = {}}, {tool = "profile_get", scope = {}}, {tool = "request_capability", scope = {}},
    {tool = "install_status", scope = {workspace_id = "home"}}, {tool = "uninstall_request", scope = {workspace_id = "home"}},
    {tool = "install_request", scope = {}}}

local function define_tests()
    test.describe("Folded gateway tools", function()
        test.it("names each carrier once where its first member stood", function()
            test.eq(table.concat(folds.names({"thread_read", "session_close", "session_cancel", "session_rename", "profile_get",
                "profile_put", "publish_status", "request_capability", "capability_status", "install_request"}), ","),
                "thread_read,session_manage,session_cancel,profile,hub_publish,elevation,hub_install")
            test.eq(table.concat(folds.names({"docs", "overlay"}), ","), "docs,overlay")
        end)
        test.it("moves a selection to its carriers without widening what it admits", function()
            local folded = folds.selection(SELECTION)
            test.eq(table.concat(tools(folded), ","), "session_open,session_manage,profile,elevation,hub_install")
            local by: {[string]: Object} = {}
            for _, raw in ipairs(folded) do
                local item = assert(bounds.object(raw))
                by[tostring(item.tool)] = assert(bounds.object(item.scope))
            end
            test.is_nil(by.session_manage.operations)
            test.eq(table.concat(assert(bounds.ids(by.profile.operations, true)), ","), "get")
            test.eq(table.concat(assert(bounds.ids(by.elevation.operations, true)), ","), "request")
            test.eq(table.concat(assert(bounds.ids(by.hub_install.operations, true)), ","), "uninstall,status")
            test.eq(by.hub_install.workspace_id, "home")
            local bounded = folds.selection({{tool = "session_close", scope = {operations = {"close"}}}})
            test.eq(#bounded, 0)
        end)
        test.it("holds a folded partial selection to the operations it named", function()
            local profile = assert(access.decode({mcp = folds.selection({{tool = "session_close", scope = {}}})}))
            local operation = "bee.threads.sessions:contract.close"
            test.is_nil(scope.check(profile, "session_manage", operation, "home", {operation = "close", session = "bs:n:home:s"}))
            test.not_nil(scope.check(profile, "session_manage", "bee.threads.sessions:contract.remove", "home",
                {operation = "remove", session = "bs:n:home:s"}))
            test.not_nil(scope.check(profile, "session_close", operation, "home", {session = "bs:n:home:s"}))
        end)
        test.it("retires every folded name so no component redeclares it", function()
            for _, name in ipairs({"session_close", "session_remove", "session_rename", "profile_get", "profile_list", "profile_put",
                "request_capability", "capability_status", "install_request", "uninstall_request", "install_status",
                "publish_request", "publish_status"}) do
                test.is_true(mcp.is_retired_tool(name), name)
                test.is_nil(mcp.tool(name), name)
                local raw = {tools = {{name = name, operation = "bee.test:legacy", description = "legacy",
                    policies = {"bee.gateway.env:tool_session_policy_ref"}, schema = {type = "object", additionalProperties = false},
                    annotations = {readOnlyHint = false}}}, traits = {}, base_tools = {}, active_traits = {}, fixed_context = {}, dynamic_keys = {}}
                test.is_nil((surface.prepare(raw, mcp.TOOLS, {name})))
            end
            for _, name in ipairs({"session_manage", "profile", "elevation", "hub_install", "hub_publish"}) do
                test.is_false(mcp.is_retired_tool(name))
                test.not_nil(mcp.tool(name), name)
            end
        end)
        test.it("moves saved profiles, sessions, trait declarations, grants and bindings to the carriers", function()
            local db = assert(sql.get(DATABASE))
            for _, statement in ipairs({
                "CREATE TABLE bee_sync_feeds (owner_id TEXT NOT NULL, feed TEXT NOT NULL, head_sequence INTEGER NOT NULL, earliest_sequence INTEGER NOT NULL, PRIMARY KEY(owner_id, feed))",
                "CREATE TABLE bee_sync_projections (owner_id TEXT NOT NULL, feed TEXT NOT NULL, projection_key TEXT NOT NULL, value_json TEXT, tombstone INTEGER NOT NULL, PRIMARY KEY(owner_id, feed, projection_key))",
                "CREATE TABLE bee_sessions (session_ref TEXT PRIMARY KEY, route_json TEXT NOT NULL)",
                "CREATE TABLE bee_session_traits (session_ref TEXT NOT NULL, trait_id TEXT NOT NULL, declaration_json TEXT NOT NULL, PRIMARY KEY(session_ref, trait_id))",
                "CREATE TABLE bee_session_trait_intervals (session_ref TEXT NOT NULL, trait_id TEXT NOT NULL, generation INTEGER NOT NULL, declaration_json TEXT NOT NULL, PRIMARY KEY(session_ref, trait_id, generation))",
                "CREATE TABLE bee_approval_grants (grant_id TEXT PRIMARY KEY, domain TEXT NOT NULL, scope_json TEXT NOT NULL)",
                "CREATE TABLE bee_gateway_bindings (binding_id TEXT PRIMARY KEY, tools_json TEXT NOT NULL)",
            }) do assert(db:execute(statement)) end
            local profile = {schema_revision = "bee.agent-profile@3", name = "Reviewer", bee = {mcp = SELECTION},
                draft = {bee = {mcp = {{tool = "profile_put", scope = {}}}}}}
            local untouched = {schema_revision = "bee.agent-profile@3", name = "Reader", bee = {mcp = {{tool = "docs", scope = {}}}}}
            assert(db:execute("INSERT INTO bee_sync_feeds VALUES ('node', 'harness.profiles:home', 4, 1), ('node', 'harness.profiles:other', 2, 1)"))
            assert(db:execute("INSERT INTO bee_sync_projections VALUES ('node', 'harness.profiles:home', 'p1', ?, 0), ('node', 'harness.profiles:other', 'p2', ?, 0)",
                {json.encode(profile), json.encode(untouched)}))
            local route = {profile_digest = "stale", effective_profile = {bee = {mcp = SELECTION}, mcp_tools = {"session_open", "session_close", "session_remove", "profile_list"}}}
            assert(db:execute("INSERT INTO bee_sessions VALUES ('bs:n:home:s', ?)", {json.encode(route)}))
            local trait = {id = "bee.mcp:sessions", title = "Sessions", prompt = "Manage", tools = {"session_open", "session_close", "session_rename"}}
            assert(db:execute("INSERT INTO bee_session_traits VALUES ('bs:n:home:s', 'bee.mcp:sessions', ?)", {json.encode(trait)}))
            assert(db:execute("INSERT INTO bee_session_trait_intervals VALUES ('bs:n:home:s', 'bee.mcp:sessions', 1, ?)", {json.encode(trait)}))
            assert(db:execute("INSERT INTO bee_approval_grants VALUES ('consent', 'profile_choices', ?), ('access', 'gateway_access', ?)",
                {json.encode({type = "exact", parameters = {configuration = {bee = {mcp = SELECTION}, mcp_tools = {"publish_request"}}}}),
                    json.encode({type = "exact", parameters = {payload = {declarations = {trait}}}})}))
            local names = {}
            for _, item in ipairs(SELECTION) do names[#names + 1] = item.tool end
            assert(db:execute("INSERT INTO bee_gateway_bindings VALUES ('binding', ?)", {json.encode(names)}))
            for _, id in ipairs({"bee.harness.migrations:tool_folds", "bee.threads.migrations:tool_folds",
                "bee.approvals.migrations:tool_folds", "bee.gateway.migrations:tool_folds"}) do migrate(id) end

            local saved = decoded(db, "SELECT value_json AS value FROM bee_sync_projections WHERE projection_key = 'p1'")
            test.eq(table.concat(tools(assert(bounds.object(saved.bee)).mcp), ","), "session_open,session_manage,profile,elevation,hub_install")
            test.eq(table.concat(tools(assert(bounds.object(assert(bounds.object(saved.draft)).bee)).mcp), ","), "profile")
            local feeds = assert(db:query("SELECT feed, head_sequence, earliest_sequence FROM bee_sync_feeds ORDER BY feed"))
            test.eq(feeds[1].head_sequence, 5)
            test.eq(feeds[1].earliest_sequence, 6)
            test.eq(feeds[2].head_sequence, 2)
            test.eq(decoded(db, "SELECT value_json AS value FROM bee_sync_projections WHERE projection_key = 'p2'").name, "Reader")

            local moved = decoded(db, "SELECT route_json AS value FROM bee_sessions")
            local effective = assert(bounds.object(moved.effective_profile))
            test.eq(table.concat(assert(bounds.ids(effective.mcp_tools, true)), ","), "session_open,session_manage,profile")
            test.eq(moved.profile_digest, (assert(canonical.digest(effective))))
            for _, table_name in ipairs({"bee_session_traits", "bee_session_trait_intervals"}) do
                local declaration = decoded(db, "SELECT declaration_json AS value FROM " .. table_name)
                test.eq(table.concat(assert(bounds.ids(declaration.tools, true)), ","), "session_open,session_manage")
            end

            local consent = decoded(db, "SELECT scope_json AS value FROM bee_approval_grants WHERE grant_id = 'consent'")
            local configuration = assert(bounds.object(assert(bounds.object(consent.parameters)).configuration))
            test.eq(table.concat(tools(assert(bounds.object(configuration.bee)).mcp), ","), "session_open,session_manage,profile,elevation,hub_install")
            test.eq(table.concat(assert(bounds.ids(configuration.mcp_tools, true)), ","), "hub_publish")
            local declared = decoded(db, "SELECT scope_json AS value FROM bee_approval_grants WHERE grant_id = 'access'")
            local payload = assert(bounds.object(assert(bounds.object(declared.parameters)).payload))
            local declaration = assert(bounds.object(assert(bounds.array(payload.declarations, 16))[1]))
            test.eq(table.concat(assert(bounds.ids(declaration.tools, true)), ","), "session_open,session_manage")

            local binding = assert(db:query("SELECT tools_json FROM bee_gateway_bindings"))[1]
            test.eq(table.concat(assert(bounds.ids(json.decode(tostring(binding.tools_json)), true)), ","),
                "session_open,session_manage,profile,elevation,hub_install")
            db:release()
        end)
    end)
end
return test.run_cases(define_tests)
