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

local function requirement(app: string, name: string, capability: string, parameters: Object): Object
    return {id = app .. "_" .. name, expected_kind = "security.policy", targets = {app},
        capability_request = {capability = capability, parameters = parameters, template_revision = 1,
            catalog_revision = model.revisions(vocabulary(), capability), reason = "test",
            target = app, path = ".security.policies +="}}
end

-- install composes what activation installs for app: its generated policies,
-- database, grant record and requirement defaults, and the admission that
-- binds the generated policies to the application.
local function install(app: string, tools: {string}): Installed
    local owner = "bee.gov.apps:" .. WORKSPACE .. "." .. app:gsub("[^%w]", "_")
    local proposal = assert(grants.propose(vocabulary(), owner, app, {
        requirement(app, "tools", "agent.tools", {tools = tools}),
        requirement(app, "notes", "app.database", {name = "notes"})}))
    local record = assert(grants.record(owner, WORKSPACE, app, proposal, "approval-" .. app, 1))
    local entries: {Object} = {record}
    local policy_ids: {string} = {}
    local tools_policy = ""
    for index, policy in ipairs(proposal.policies) do
        entries[#entries + 1] = policy
        policy_ids[#policy_ids + 1] = tostring(policy.id)
        local grant = proposal.capabilities[index]
        if grant and grant.capability == "agent.tools" then tools_policy = tostring(proposal.bindings[index].policy_id) end
    end
    for _, database in ipairs(proposal.databases) do entries[#entries + 1] = database end
    for _, binding in ipairs(proposal.bindings) do
        entries[#entries + 1] = {id = binding.requirement_id, kind = "ns.requirement", meta = {}, data = {default = binding.policy_id}}
    end
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
            remove({installed.tools_policy})
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
