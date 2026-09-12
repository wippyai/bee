-- MIT. Plan tests use a pure artifact source; no Hub or registry writer runs.
local test = require("test")
local plan = require("plan")
local graph = require("graph")
local inspect = require("inspect")
local requirements = require("requirements")

local function root(component: string, version: string): {[string]: unknown}
    local id, problem = plan.root_id(component)
    if not id then error(problem or "cannot make root id") end
    return {id = id, kind = "ns.dependency", registry = {owner = "", root = true},
        data = {component = component, version = version, parameters = {}}}
end

local function state(entries: {unknown}, modules: {unknown}?): {[string]: unknown}
    local result: {[string]: unknown} = {entries = entries}
    if modules then result.resolution = {modules = modules} end
    return result
end

local function package(name: string, version: string, digest: string, entries: {inspect.Entry}?,
    holes: requirements.Result?): inspect.Inspection
    local selected: requirements.Result = {requirements = {}, missing = {}}
    if holes then selected = holes end
    return {component = name, version = version, digest = string.rep(digest, 64),
        entries = entries or {}, requirements = selected}
end

local function source(items: {[string]: inspect.Inspection}): graph.Source
    return {
        versions = function(_: string, _: integer): ({string}?, boolean?, string?)
            return nil, nil, "exact pins do not list versions"
        end,
        artifact = function(component: string, version: string): (inspect.Inspection?, string?)
            local found = items[component .. "@" .. version]
            if not found then return nil, "missing artifact" end
            return found, nil
        end,
    }
end

local function request(raw: unknown): plan.Request
    local decoded, problem = plan.decode(raw)
    if not decoded then error(problem or "cannot decode request") end
    return decoded
end

local function module_for(items: {plan.Module}, component: string): plan.Module?
    for _, item in ipairs(items) do
        if type(item) == "table" and item.component == component then return item end
    end
    return nil
end

local function define_tests()
    test.describe("Hub dependency plan", function()
        test.it("accepts only exact install/update requests and bounded action-specific fields", function()
            local decoded, problem = plan.decode({action = "install", component = "acme/app", version = "v1.2.3",
                parameters = {{name = "acme.app:port", value = 8080}}})
            test.is_nil(problem)
            test.not_nil(decoded)
            if decoded then
                test.eq(decoded.action, "install")
                test.eq(decoded.version, "v1.2.3")
                test.eq(decoded.migration_policy, "none")
                test.eq(decoded.parameters[1].name, "acme.app:port")
            end
            for _, raw in ipairs({
                {action = "install", component = "acme/app", version = "^1.0.0"},
                {action = "delete", component = "acme/app", version = "1.0.0"},
                {action = "uninstall", component = "acme/app", version = "1.0.0"},
                {action = "uninstall", component = "acme/app", parameters = {}},
                {action = "update", component = "acme/app", version = "1.0.0", migration_policy = "down"},
                {action = "install", component = "acme/app", version = "1.0.0", registry = "caller-selected"},
            }) do
                test.is_nil(plan.decode(raw))
            end
        end)

        test.it("refuses an existing root whose registry-selected id is not Bee's Hub root", function()
            local prepared, problem = plan.prepare(state({
                {id = "host.config:app", kind = "ns.dependency", registry = {owner = "", root = true},
                    data = {component = "acme/app", version = "1.0.0"}},
            }), 4, request({action = "update", component = "acme/app", version = "1.1.0"}), source({}))
            test.is_nil(prepared)
            test.not_nil(problem)
        end)

        test.it("binds digest to the captured base revision and selected artifact", function()
            local req = request({action = "install", component = "acme/app", version = "1.0.0"})
            local first, first_problem = plan.prepare(state({}), 7, req,
                source({["acme/app@1.0.0"] = package("acme/app", "1.0.0", "a")}))
            local moved, moved_problem = plan.prepare(state({}), 8, req,
                source({["acme/app@1.0.0"] = package("acme/app", "1.0.0", "a")}))
            local changed, changed_problem = plan.prepare(state({}), 7, req,
                source({["acme/app@1.0.0"] = package("acme/app", "1.0.0", "b")}))
            test.is_nil(first_problem); test.is_nil(moved_problem); test.is_nil(changed_problem)
            test.not_nil(first); test.not_nil(moved); test.not_nil(changed)
            if first and moved and changed then
                test.eq(first.plan.base_revision, 7)
                test.eq(moved.plan.base_revision, 8)
                test.neq(first.plan.digest, moved.plan.digest)
                test.neq(first.plan.digest, changed.plan.digest)
            end
        end)

        test.it("preserves other Hub roots across update and uninstall", function()
            local app_root = root("acme/app", "1.0.0")
            local other_root = root("acme/other", "1.0.0")
            local installed = state({app_root, other_root}, {
                {name = "acme/app", version = "1.0.0", source = "hub"},
                {name = "acme/other", version = "1.0.0", source = "hub"},
            })
            local artifacts = source({
                ["acme/app@1.1.0"] = package("acme/app", "1.1.0", "a"),
                ["acme/other@1.0.0"] = package("acme/other", "1.0.0", "b"),
            })
            local update, update_problem = plan.prepare(installed, 3,
                request({action = "update", component = "acme/app", version = "1.1.0"}), artifacts)
            local uninstall, uninstall_problem = plan.prepare(installed, 3,
                request({action = "uninstall", component = "acme/app"}), artifacts)
            test.is_nil(update_problem); test.is_nil(uninstall_problem)
            test.not_nil(update); test.not_nil(uninstall)
            if update then
                local app, other = module_for(update.plan.modules, "acme/app"), module_for(update.plan.modules, "acme/other")
                test.not_nil(app); test.not_nil(other)
                if app then test.eq(app.change, "update") end
                if other then test.eq(other.change, "keep") end
            end
            if uninstall then
                local removed, retained = module_for(uninstall.plan.modules, "acme/app"), module_for(uninstall.plan.modules, "acme/other")
                test.not_nil(removed); test.not_nil(retained)
                if removed then test.eq(removed.change, "remove") end
                if retained then test.eq(retained.change, "keep") end
            end
        end)

        test.it("refuses package entries that collide with another registry owner", function()
            local prepared, problem = plan.prepare(state({
                {id = "acme.app:entry", kind = "library.lua", registry = {owner = "other/module", root = false}},
            }), 1, request({action = "install", component = "acme/app", version = "1.0.0"}), source({
                ["acme/app@1.0.0"] = package("acme/app", "1.0.0", "a",
                    {{id = "acme.app:entry", kind = "library.lua", meta = {}, data = {}}}),
            }))
            test.is_nil(prepared)
            test.not_nil(problem)
        end)

        test.it("carries requested parameters into the selected package requirements", function()
            local prepared, problem = plan.prepare(state({}), 1,
                request({action = "install", component = "acme/app", version = "1.0.0",
                    parameters = {{name = "acme.app:port", value = 8080}}}), source({
                    ["acme/app@1.0.0"] = package("acme/app", "1.0.0", "a", {
                        {id = "acme.app:port", kind = "ns.requirement", meta = {},
                            data = {targets = {{entry = "acme.app:main", path = "settings.port"}}}},
                        {id = "acme.app:main", kind = "library.lua", meta = {}, data = {}},
                    }, {requirements = {{
                        id = "acme.app:port", has_default = false, has_selected = false,
                        targets = {{entry = "acme.app:main", path = "settings.port"}},
                    }}, missing = {"acme.app:port"}}),
                }))
            test.is_nil(problem)
            test.not_nil(prepared)
            if prepared then
                local item = prepared.plan.modules[1]
                test.eq(item.requirements.requirements[1].id, "acme.app:port")
                test.is_true(item.requirements.requirements[1].has_selected)
                test.eq(item.requirements.requirements[1].selected, 8080)
                test.is_true(prepared.plan.ready)
            end
        end)
    end)
end

return test.run_cases(define_tests)
