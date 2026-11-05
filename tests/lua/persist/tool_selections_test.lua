-- MIT. Retired tool ids move to the traits that carry them in saved profiles,
-- profile and trait consents, session routes and session trait declarations,
-- without touching user text, other keys or the profile's identity.
local test = require("test")
local sql = require("sql")
local json = require("json")
local funcs = require("funcs")
local canonical = require("canonical")
type Object = {[string]: any}
local DATABASE = "bee.tests.persist:tool_selections_db"
local OLD = "bee.gov.binding:overlay_call"
local NEW = "bee.gov.traits:overlay_call"
local RETIRED = {OLD, "bee.gov.binding:delivery_call", "bee.node.binding:tests_call", "bee.hub.binding:call", "bee.docs.binding:call"}
local MOVED = {NEW, "bee.gov.traits:delivery_call", "bee.gov.traits:tests_call", "bee.hub.traits:call", "bee.docs.traits:call"}
local TABLES = {"bee_sync_projections", "bee_sync_feeds", "bee_approval_grants", "bee_sessions", "bee_session_traits", "bee_session_trait_intervals"}

local function migrate(id: string)
    local reply, err = funcs.call(id, {target_db = "bee:db", database_id = DATABASE, direction = "up", id = id})
    assert(not err, tostring(err))
    assert(type(reply) == "table" and reply.status ~= "error", tostring(type(reply) == "table" and reply.error))
end

local function stored(db: sql.DB, statement: string): Object
    local rows = assert(db:query(statement))
    test.eq(#rows, 1)
    return assert(json.decode(tostring(rows[1].value))) :: Object
end

local function dump(db: sql.DB): string
    local parts: {string} = {}
    for _, name in ipairs(TABLES) do
        for _, row in ipairs(assert(db:query("SELECT * FROM " .. name .. " ORDER BY rowid"))) do parts[#parts + 1] = assert(canonical.encode(row)) end
    end
    return table.concat(parts, "\n")
end

local function selections(tools: {string}): {Object}
    local items: {Object} = {}
    for _, tool in ipairs(tools) do items[#items + 1] = {tool = tool, scope = {}} end
    return items
end

local function names(items: {Object}): string
    local tools: {string} = {}
    for _, item in ipairs(items) do tools[#tools + 1] = tostring(item.tool) end
    return table.concat(tools, ",")
end

local function upgrade(ids: {string}, literal_key: boolean)
    local db = assert(sql.get(DATABASE))
    for _, name in ipairs(TABLES) do assert(db:execute("DROP TABLE IF EXISTS " .. name)) end
    assert(db:execute("DROP TABLE IF EXISTS _migrations"))
    for _, statement in ipairs({
        "CREATE TABLE bee_sync_projections (owner_id TEXT, feed TEXT, projection_key TEXT, value_json TEXT, tombstone INTEGER)",
        "CREATE TABLE bee_sync_feeds (owner_id TEXT, feed TEXT, head_sequence INTEGER, earliest_sequence INTEGER)",
        "CREATE TABLE bee_approval_grants (grant_id TEXT, domain TEXT, scope_json TEXT)",
        "CREATE TABLE bee_sessions (session_ref TEXT, route_json TEXT)",
        "CREATE TABLE bee_session_traits (session_ref TEXT, declaration_json TEXT)",
        "CREATE TABLE bee_session_trait_intervals (session_ref TEXT, declaration_json TEXT)",
    }) do assert(db:execute(statement)) end
    local profile: Object = {name = OLD, bee = {mcp = {{tool = OLD, scope = {note = OLD}}, {tool = "external:tool", scope = {}}}}, mcp_tools = RETIRED,
        draft = {bee = {mcp = selections(RETIRED)}, mcp_tools = RETIRED}, user_fields = {mcp_tools = {OLD}}}
    if literal_key then profile["bee.mcp"] = {{tool = OLD}} end
    local declaration = {id = "bee.gov.traits:authoring_trait", tools = RETIRED, prompt = OLD}
    assert(db:execute("INSERT INTO bee_sync_projections VALUES ('owner', 'harness.profiles:workspace', 'profile', ?, 0)", {json.encode(profile)}))
    assert(db:execute("INSERT INTO bee_sync_feeds VALUES ('owner', 'harness.profiles:workspace', 7, 1)"))
    assert(db:execute("INSERT INTO bee_approval_grants VALUES ('profile-consent', 'profile_choices', ?)", {json.encode({parameters = {configuration = profile}})}))
    assert(db:execute("INSERT INTO bee_approval_grants VALUES ('trait-consent', 'gateway_access', ?)", {json.encode({parameters = {payload = {declarations = {declaration}}}})}))
    assert(db:execute("INSERT INTO bee_sessions VALUES ('session', ?)", {json.encode({effective_profile = profile, profile_digest = "before", note = OLD})}))
    for _, name in ipairs({"bee_session_traits", "bee_session_trait_intervals"}) do
        assert(db:execute("INSERT INTO " .. name .. " VALUES ('session', ?)", {json.encode(declaration)}))
    end

    for _, id in ipairs(ids) do migrate(id) end
    local first = dump(db)
    assert(db:execute("DELETE FROM _migrations"))
    for _, id in ipairs(ids) do migrate(id) end
    test.eq(dump(db), first)

    local upgraded = stored(db, "SELECT value_json AS value FROM bee_sync_projections")
    test.eq(upgraded.bee.mcp[1].tool, NEW)
    test.eq(upgraded.bee.mcp[1].scope.note, OLD)
    test.eq(upgraded.bee.mcp[2].tool, "external:tool")
    test.eq(table.concat(upgraded.mcp_tools, ","), table.concat(MOVED, ","))
    test.eq(table.concat(upgraded.draft.mcp_tools, ","), table.concat(MOVED, ","))
    test.eq(names(upgraded.draft.bee.mcp), table.concat(MOVED, ","))
    if literal_key then test.eq(upgraded["bee.mcp"][1].tool, OLD) end
    test.eq(upgraded.user_fields.mcp_tools[1], OLD)
    test.eq(upgraded.name, OLD)
    local feed = assert(db:query("SELECT head_sequence, earliest_sequence FROM bee_sync_feeds"))[1]
    test.eq(feed.head_sequence, 8)
    test.eq(feed.earliest_sequence, 9)

    local consent = stored(db, "SELECT scope_json AS value FROM bee_approval_grants WHERE grant_id = 'profile-consent'")
    test.eq(canonical.encode(consent.parameters.configuration), canonical.encode(upgraded))
    local trait = stored(db, "SELECT scope_json AS value FROM bee_approval_grants WHERE grant_id = 'trait-consent'").parameters.payload.declarations[1]
    for _, name in ipairs({"bee_session_traits", "bee_session_trait_intervals"}) do
        local saved = stored(db, "SELECT declaration_json AS value FROM " .. name)
        test.eq(canonical.encode(saved), canonical.encode(trait))
        test.eq(table.concat(saved.tools, ","), table.concat(MOVED, ","))
        test.eq(saved.prompt, OLD)
    end
    local route = stored(db, "SELECT route_json AS value FROM bee_sessions")
    test.eq(canonical.encode(route.effective_profile), canonical.encode(upgraded))
    test.eq(route.profile_digest, (assert(canonical.digest(upgraded))))
    test.eq(route.note, OLD)
    db:release()
end

local SELECTIONS = {"bee.harness.migrations:tool_selections", "bee.approvals.migrations:tool_selections", "bee.threads.migrations:tool_selections"}
local REPAIRS = {"bee.harness.migrations:tool_selection_paths", "bee.approvals.migrations:tool_selection_paths", "bee.threads.migrations:tool_selection_paths"}

local function define_tests()
    test.describe("retired tool selection migrations", function()
        test.it("upgrade existing selections without changing user text or identity", function()
            local ids: {string} = {}
            for index = 1, #SELECTIONS do ids[#ids + 1] = SELECTIONS[index]; ids[#ids + 1] = REPAIRS[index] end
            upgrade(ids, false)
        end)
        test.it("upgrade selections through the repair alone, leaving a literal dotted key untouched", function()
            upgrade(REPAIRS, true)
        end)
    end)
end
return test.run_cases(define_tests)
