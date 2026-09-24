-- MIT. Components attach per-workspace data and search to the catalog through
-- workspace extension bindings: inspect shows every binding's description
-- beside the applications a checkpoint keeps open, search_within asks every
-- binding, and a failing binding never hides the others.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local time = require("time")
local fs = require("fs")
local persistence = require("persistence")
local model = require("model")
local appearance = require("appearance")

local PROJECTS = "bee.workspace.catalog:projects_fixture"
local RESOURCES = "bee:resources_workspace_extension"
local AGENTS = "bee:gateway_workspace_extension"
local BROKEN = "bee.workspace.catalog:broken_extension"
type Object = {[string]: unknown}
type Reply = {ok: boolean, error: {code: string, message: string}?, value: unknown}

local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end

local function executor(id: string, names: {string}): funcs.Executor
    local policies: {security.Policy} = {}
    for _, name in ipairs(names) do policies[#policies + 1] = assert(security.policy(name)) end
    return funcs.new():with_actor(security.new_actor(id)):with_scope(security.new_scope(policies))
end

local manager = executor("bee.test.extension_manager", {"bee.workspace.catalog:call_test_policy", "bee:workspace_catalog_read_policy",
    "bee:workspace_catalog_manage_policy", "bee.workspace.catalog:resources_call_test_policy", "bee:resource_manage_policy"})
local reader = executor("bee.test.extension_reader", {"bee.workspace.catalog:call_test_policy", "bee:workspace_catalog_read_policy"})
local stranger = executor("bee.test.extension_stranger", {"bee.workspace.catalog:resources_call_test_policy"})

local function call(client: funcs.Executor, target: string, value: unknown): Reply
    local reply, err = client:call(target, value)
    if err then error(target .. ": " .. tostring(err)) end
    return reply :: Reply
end

local function value(reply: Reply): Object
    if not reply.ok then error(tostring(reply.error and reply.error.code) .. ": " .. tostring(reply.error and reply.error.message)) end
    return reply.value :: Object
end

local function admit()
    local entry = registry.get("bee:resource_roots")
    if not entry then error("admitted roots entry") end
    local roots = (entry.data :: Object).roots :: {Object}
    for _, root in ipairs(roots) do if root.root_ref == PROJECTS then return end end
    roots[#roots + 1] = {root_ref = PROJECTS, access = "write"}
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("admit roots: " .. tostring(err)) end
end

local function workspace(label: string): string
    admit()
    local name = fresh("extension")
    local volume = assert(fs.get(PROJECTS))
    assert(volume:mkdir(name))
    return tostring(value(call(manager, "bee.workspace.catalog:create", {label = label, root_ref = PROJECTS, subpath = name})).workspace_id)
end

local function extension(inspected: Object, binding: string): Object
    for _, item in ipairs(inspected.extensions :: {Object}) do
        if item.binding == binding then return item end
    end
    error("extension " .. binding .. " is missing")
end

local function define_tests()
    test.describe("Workspace extensions", function()
        test.it("describes what each extension holds for the workspace beside its checkpointed applications", function()
            local id = workspace("Described")
            for _, name in ipairs({"docs", "project"}) do
                value(call(manager, "bee.resources.binding:associate", {workspace_id = id, name = name, root_ref = PROJECTS, subpath = "", allowed_access = "read"}))
            end
            local saved = assert(persistence.open(nil, {workspace_id = id}))
            assert(saved:write({version = 1, desktop = {scene = model.new(80, 24), tabs = {}, preferences = appearance.defaults()},
                applications = {{id = "view-1", instance_id = "instance-1", definition_id = "bee.settings:app", resume_schema = "settings.v1",
                    restart_policy = "automatic", resume_state = ""}}}))
            saved:close()
            local inspected = value(call(reader, "bee.workspace.catalog:inspect", {workspace_id = id}))
            test.eq((inspected.workspace :: Object).label, "Described")
            test.eq(inspected.live, false)
            local applications = inspected.applications :: {Object}
            test.eq(#applications, 1)
            test.eq(applications[1].definition_id, "bee.settings:app")
            test.eq(applications[1].instance_id, "instance-1")
            local resources = extension(inspected, RESOURCES)
            test.eq(resources.title, "Resources")
            test.eq(resources.total, 2)
            test.is_nil(resources.error)
            local items = resources.items :: {Object}
            test.eq(items[1].label, "docs")
            test.contains(tostring(items[1].detail), PROJECTS)
            local agents = extension(inspected, AGENTS)
            test.eq(agents.title, "Agent sessions")
            test.is_nil(agents.error)
            test.eq(agents.total, 0)
        end)

        test.it("searches inside one workspace through every extension", function()
            local id = workspace("Searched")
            for _, name in ipairs({"alpha-notes", "alpha-code", "beta"}) do
                value(call(manager, "bee.resources.binding:associate", {workspace_id = id, name = name, root_ref = PROJECTS, subpath = "", allowed_access = "read"}))
            end
            local found = value(call(reader, "bee.workspace.catalog:search_within", {workspace_id = id, text = "alpha", limit = 5}))
            local resources: Object? = nil
            for _, item in ipairs(found.results :: {Object}) do if item.binding == RESOURCES then resources = item end end
            if not resources then error("resources results missing") end
            local hits = resources.hits :: {Object}
            test.eq(#hits, 2)
            test.eq(hits[1].label, "alpha-code")
            test.eq(hits[2].label, "alpha-notes")
            local missing = call(reader, "bee.workspace.catalog:search_within", {workspace_id = string.rep("0", 32), text = "alpha"})
            test.eq(missing.error and missing.error.code, "NOT_FOUND")
        end)

        test.it("keeps the other extensions when one fails", function()
            local id = workspace("Resilient")
            local inspected = value(call(reader, "bee.workspace.catalog:inspect", {workspace_id = id}))
            local broken = extension(inspected, BROKEN)
            test.contains(tostring(broken.error), "deliberately")
            test.is_nil(extension(inspected, RESOURCES).error)
        end)

        test.it("answers only callers that may read the workspace", function()
            local id = workspace("Private")
            local denied = call(stranger, "bee.resources.binding:describe", {workspace_id = id})
            test.eq(denied.ok, false)
            test.eq(denied.error and denied.error.code, "DENIED")
            local sessions = call(stranger, "bee.gateway.binding:describe", {workspace_id = id})
            test.eq(sessions.error and sessions.error.code, "DENIED")
            local unread = call(executor("bee.test.extension_outsider", {"bee.workspace.catalog:call_test_policy"}), "bee.workspace.catalog:inspect", {workspace_id = id})
            test.eq(unread.error and unread.error.code, "DENIED")
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
