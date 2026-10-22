-- MIT. Applications offer agents the tool functions the person approved
-- through agent.tools. Discovery lists them for the caller's workspace, and a
-- call runs the tool as the application, with its actor and exact scope, so it
-- reaches the application's own granted database. Withdrawing the grant, or
-- two applications offering one name, takes the tool away.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local bounds = require("bounds")
local model = require("capability_model")
local grants = require("capability_grants")

local app_traits = require("app_traits")
local app_identity = require("app_identity")
local surface = require("surface")
local catalog = require("catalog")
local mcp = require("mcp")
local launch_policy = require("launch_policy")
local profile_scope = require("profile_scope")
local profile_validation = require("profile_validation")
local profile_protocol = require("profile_protocol")

local WORKSPACE = string.rep("f", 32)
local APP = "bee.tests.node:tools_app"
local TWIN = "bee.tests.node:tools_twin"
local ADD = "bee.tests.node:tools_add"
local LIST = "bee.tests.node:tools_list"
local TWIN_ADD = "bee.tests.node:tools_twin_add"

type Object = {[string]: unknown}
type Installed = {ids: {string}, tools_policy: string}

local function vocabulary(): model.Vocabulary
    return assert(model.decode(assert(registry.get("bee.capability:catalog"))))
end

local function request(app: string, capability: string, parameters: Object): Object
    return {application = app, package = "test", capability = capability, parameters = parameters, template_revision = 1,
            catalog_revision = model.revisions(vocabulary(), capability), reason = "test"}
end

-- install composes what activation installs for app: its generated policies,
-- database and grant record, and the admission that
-- binds the generated policies to the application.
local function install(app: string, tools: {string}): Installed
    local owner = "bee.gov.apps:" .. WORKSPACE .. "." .. app:gsub("[^%w]", "_")
    local proposal = assert(grants.propose(vocabulary(), owner, app, {
        request(app, "agent.tools", {tools = tools}),
        request(app, "app.database", {name = "notes"})}))
    local record = assert(grants.record(owner, WORKSPACE, app, proposal, "approval-" .. app, 1))
    local entries: {Object} = {record}
    local policy_ids: {string} = {}
    local tools_policy = ""
    for index, policy in ipairs(proposal.policies) do
        entries[#entries + 1] = policy
        policy_ids[#policy_ids + 1] = tostring(policy.id)
        local grant = proposal.capabilities[index]
        if grant and grant.capability == "agent.tools" then tools_policy = tostring(policy.id) end
    end
    for _, database in ipairs(proposal.databases) do entries[#entries + 1] = database end
    entries[#entries + 1] = {id = app .. "_admission", kind = "registry.entry",
        meta = {type = "bee.node.application_admission"},
        data = {bindings = {{definition_id = app, policies = policy_ids}}}}
    local changes = assert(registry.snapshot()):changes()
    local ids: {string} = {}
    for _, entry in ipairs(entries) do
        local id = assert(bounds.id(entry.id))
        changes:create({id = id, kind = assert(bounds.text(entry.kind, 160)), meta = bounds.object(entry.meta) or {}, data = entry.data})
        ids[#ids + 1] = id
    end
    assert(changes:apply())
    return {ids = ids, tools_policy = tools_policy}
end

local function remove(ids: {string})
    local changes = assert(registry.snapshot()):changes()
    for _, id in ipairs(ids) do if registry.get(id) then changes:delete(id) end end
    assert(changes:apply())
end

local function call(target: string, request: Object): Object
    local actor = assert(security.new_actor("bee.tests.tools_agent", {workspace_id = WORKSPACE}))
    local raw, err = funcs.new():with_actor(actor):call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    return assert(bounds.object(raw))
end

local function value(reply: Object): Object
    if reply.ok ~= true then error("refused: " .. tostring((bounds.object(reply.error) or {}).message)) end
    return assert(bounds.object(reply.value))
end

local function aliases(listed: Object): string
    local names: {string} = {}
    for _, raw in ipairs(listed.tools :: {unknown}) do names[#names + 1] = tostring((assert(bounds.object(raw))).alias) end
    return table.concat(names, ",")
end

local function codes(listed: Object): string
    local found: {string} = {}
    for _, raw in ipairs(listed.diagnostics :: {unknown}) do found[#found + 1] = tostring((assert(bounds.object(raw))).code) end
    return table.concat(found, ",")
end

local function define_tests()
    test.describe("application agent tools", function()
        test.it("catalogs Progress by admission and exposes only its selected tools, then removes it on uninstall", function()
            local installed = install(APP, {ADD, LIST})
            local original = assert(registry.get(TWIN_ADD))
            local distinct = assert(registry.get(TWIN_ADD))
            distinct.meta.llm_alias = "unrelated_add"
            local changed = assert(registry.snapshot()):changes()
            changed:update(distinct); assert(changed:apply())
            local twin = install(TWIN, {TWIN_ADD})
            local raw = {tools = {}, traits = {}, base_tools = {}, active_traits = {}, fixed_context = {}, dynamic_keys = {},
                access = {policy = "agent-access", traits = {"bee.app:tools"}}}
            local configured = assert((surface.prepare(raw, mcp.TOOLS, {"app_tools"}, WORKSPACE)))
            local trait_id = assert(app_identity.trait(WORKSPACE, APP, nil))
            local progress: unknown = nil
            for _, trait in ipairs(configured.catalog.traits) do
                test.is_true(trait.id ~= "bee.app:tools")
                if trait.id == trait_id then progress = trait; test.eq(trait.title, "Progress"); test.eq(table.concat(trait.tools, ","), "notes_add,notes_list") end
            end
            test.not_nil(progress)
            local planned, err = launch_policy.decode("bee.driver.claude.security:launch_policy_claude_window",
                assert(registry.get("bee.driver.claude.security:launch_policy_claude_window")),
                function(_ref: string): (string?, string?) return "/usr/bin/fixture", nil end,
                {options = {}, mcp_tools = {}, instructions = "", active_traits = {trait_id}, requestable = {}})
            test.not_nil(planned, err)
            test.not_nil(bounds.member("app_tools", assert(planned).gateway_tools), "the app trait supplies its own tool mechanism")
            test.is_nil(profile_scope.check({mcp = {}}, "notes_add", "bee.node.binding:app_tool_call", WORKSPACE,
                {text = "note"}, {definition = APP, trait = trait_id}))
            test.not_nil(profile_scope.check({mcp = {{tool = "app_tools", scope = {definitions = {TWIN}}}}},
                "notes_add", "bee.node.binding:app_tool_call", WORKSPACE, {text = "note"}, {definition = APP, trait = trait_id}))

            local profile = assert(profile_protocol.profile({schema_revision = "bee.agent-profile@3", name = "App worker",
                definition_ref = "bee.driver.claude.profiles:default_window", driver_binding_ref = "bee.drivers.claude.binding:binding",
                provider = {}, bee = {mcp = {}}, active_traits = {trait_id}, requestable = {}}))
            test.is_nil(profile_validation.check(assert(registry.snapshot()), profile))
            test.is_nil(profile_validation.ceiling(assert(registry.snapshot()), profile, {trait_id}, false))
            test.not_nil(profile_validation.ceiling(assert(registry.snapshot()), profile, {}, false), "delegation cannot exceed the parent trait ceiling")
            test.is_nil(surface.select(configured, {trait_id}, {}), "an agent cannot approve its own application trait")
            local approved = assert(surface.grant(configured, {trait_id}))
            local selection = assert(surface.select(approved, {trait_id}, {}))
            local tools = assert(catalog.select(approved.catalog, approved.ceiling, approved.base_tools, approved.allowed_traits, selection.active))
            test.eq(#tools, 2)
            test.eq(tools[1].name, "notes_add")
            test.eq(tools[2].name, "notes_list")
            remove(installed.ids)
            local removed = assert(app_traits.catalog(WORKSPACE))
            for _, trait in ipairs(removed.traits) do test.is_true(trait.id ~= trait_id) end
            test.is_nil(app_traits.load(trait_id, WORKSPACE))
            remove(twin.ids)
            local restore = assert(registry.snapshot()):changes()
            restore:update(original); assert(restore:apply())
        end)
        test.it("lists the approved tools and runs them as the application against its own database", function()
            local installed = install(APP, {ADD, LIST})
            local listed = value(call("bee.node.binding:app_tools", {}))
            local added = call("bee.node.binding:app_tool_call", {tool = "notes_add", arguments = {text = "first"}})
            local read = call("bee.node.binding:app_tool_call", {tool = "notes_list", arguments = {}})
            local unknown = call("bee.node.binding:app_tool_call", {tool = "notes_missing", arguments = {}})
            remove(installed.ids)
            test.eq(aliases(listed), "notes_add,notes_list")
            local first = assert(bounds.object((listed.tools :: {unknown})[1]))
            test.eq(first.definition_id, APP)
            test.eq(first.ref, ADD)
            test.not_nil(bounds.object(first.input_schema))
            local added_value = value(added)
            test.eq(added_value.added, "first")
            test.eq(added_value.actor, "bee.application:" .. WORKSPACE .. ":agent")
            local notes = value(read).notes :: {string}
            test.eq(notes[#notes], "first")
            test.eq((assert(bounds.object(unknown.error))).code, "NOT_FOUND")
        end)
        test.it("serves a bound agent holding only the gateway's app_tools policy, as the application", function()
            local installed = install(APP, {ADD, LIST})
            local policy = assert(security.policy("bee.security.gateway:gateway_tool_app_tools_policy"))
            local actor = assert(security.new_actor("bee.tests.tools_agent", {workspace_id = WORKSPACE}))
            local executor = funcs.new():with_actor(actor):with_scope(security.new_scope({policy}))
            local listed, list_error = executor:call("bee.node.binding:app_tools", {})
            local added, add_error = executor:call("bee.node.binding:app_tool_call", {tool = "notes_add", arguments = {text = "scoped"}})
            local denied = security.new_scope({policy}):evaluate(actor, "db.get", "bee:db")
            remove(installed.ids)
            test.is_nil(list_error, tostring(list_error))
            test.is_nil(add_error, tostring(add_error))
            test.eq(aliases(value(assert(bounds.object(listed)))), "notes_add,notes_list")
            test.eq(value(assert(bounds.object(added))).added, "scoped")
            test.is_false(denied == "allow")
        end)
        test.it("takes a tool away when its grant is withdrawn", function()
            local installed = install(APP, {ADD, LIST})
            local id = assert(app_identity.trait(WORKSPACE, APP, nil))
            test.not_nil(app_traits.load(id, WORKSPACE))
            remove({installed.tools_policy})
            test.is_nil(app_traits.load(id, WORKSPACE))
            local listed = value(call("bee.node.binding:app_tools", {}))
            local refused = call("bee.node.binding:app_tool_call", {tool = "notes_add", arguments = {text = "late"}})
            remove(installed.ids)
            test.eq(aliases(listed), "")
            test.eq((assert(bounds.object(refused.error))).code, "NOT_FOUND")
        end)
        test.it("offers neither tool when two applications offer one name, and says so", function()
            local first = install(APP, {ADD, LIST})
            local second = install(TWIN, {TWIN_ADD})
            local listed = value(call("bee.node.binding:app_tools", {}))
            remove(first.ids)
            remove(second.ids)
            test.eq(aliases(listed), "notes_list")
            test.eq(codes(listed), "ALIAS_COLLISION")
        end)
    end)
end
return test.run_cases(define_tests)
