-- MIT. Plan tests use a pure artifact source; no Hub or registry writer runs.
local test = require("test")
local plan = require("plan")
local graph = require("graph")
local inspect = require("inspect")
local requirements = require("requirements")
local host_identity = require("binary_identity")
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")

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

local function binary_identity(package_name: string, version: string): inspect.Entry
    return {id = "bee.env:binary_identity", kind = "registry.entry", registry = {owner = "bee/bee"},
        meta = {type = "bee.binary_identity"}, data = {version = "0.1.0", build = "revision",
            source = "https://example.test/bee", source_revision = "revision", runtime = "https://example.test/runtime",
            runtime_commit = "runtime-commit", native = "github.com/wippyai/bee/native", native_version = version,
            website = "https://example.test", native_components = {{package = package_name, version = version}}}}
end

local function baked_identity(version: string, runtime_commit: string?): {native_module: string, native_version: string,
    native_modules: {[string]: string}, runtime_commit: string}
    local module = "github.com/wippyai/bee/native"
    return {native_module = module, native_version = version, native_modules = {[module] = version},
        runtime_commit = runtime_commit or "runtime-commit"}
end

local function package(name: string, version: string, digest: string, entries: {inspect.Entry}?,
    holes: requirements.Result?): inspect.Inspection
    local selected: requirements.Result = assert(requirements.read(entries or {}, {}))
    if holes then selected = holes end
    return {component = name, version = version, digest = string.rep(digest, 64),
        entries = entries or {}, requirements = selected, next_offset = nil, eof = true}
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
        for _, changed in ipairs({false, true}) do
            test.it(changed and "requires bindings when a kept version's artifact changes" or "preserves untouched dependency requirement holes", function()
                local captured = state({root("acme/app", "1.0.0"),
                    {id = "acme.app:dependency", kind = "ns.dependency", registry = {owner = "acme/app"},
                        data = {component = "acme/lib", version = "1.0.0", parameters = {}}},
                }, {{name = "acme/app", version = "1.0.0", digest = string.rep("a", 64)},
                    {name = "acme/lib", version = "1.0.0", digest = string.rep("c", 64)}})
                local targets = {{entry = "acme.lib:main", path = ".database"}}
                local prepared, problem = plan.prepare(captured, 1,
                    request({action = "update", component = "acme/app", version = "2.0.0"}), source({
                        ["acme/app@2.0.0"] = package("acme/app", "2.0.0", "b", {
                            {id = "acme.app:dependency", kind = "ns.dependency", meta = {},
                                data = {component = "acme/lib", version = "1.0.0", parameters = {}}}}),
                        ["acme/lib@1.0.0"] = package("acme/lib", "1.0.0", changed and "d" or "c", {
                            {id = "acme.lib:database", kind = "ns.requirement", meta = {}, data = {targets = targets}},
                            {id = "acme.lib:main", kind = "registry.entry", meta = {}, data = {}},
                        }),
                    }))
                test.is_nil(problem); test.not_nil(prepared)
                if prepared then
                    test.eq(prepared.plan.ready, not changed)
                    test.eq(#prepared.plan.missing, changed and 1 or 0)
                end
            end)
        end
        for _, constraint in ipairs({"*", ">=0.4.0 <0.5.0", ">=0.4.6", "0.4.6"}) do
            test.it("predicts runtime installed selection for " .. constraint, function()
                local captured = state({root("acme/app", "1.0.0"),
                    {id = "acme.app:test", kind = "ns.dependency", registry = {owner = "acme/app"},
                        data = {component = "wippy/test", version = "0.4.17"}},
                    {id = "wippy.test:terminal", kind = "ns.dependency", registry = {owner = "wippy/test"},
                        data = {component = "wippy/terminal", version = "*"}},
                }, {{name = "acme/app", version = "1.0.0"}, {name = "wippy/test", version = "0.4.17"},
                    {name = "wippy/terminal", version = "0.4.5"}})
                -- The live selection, rather than the shipped lock, is preferred.
                captured.resolution = {modules = {{name = "acme/app", version = "1.0.0"},
                    {name = "wippy/test", version = "0.4.17"}, {name = "wippy/terminal", version = "0.4.5"}},
                    lock = {root_module = "", modules = {{name = "wippy/terminal", version = "0.4.4"}}}}
                local artifacts = source({
                    ["acme/app@2.0.0"] = package("acme/app", "2.0.0", "a", {
                        {id = "acme.app:test", kind = "ns.dependency", meta = {},
                            data = {component = "wippy/test", version = "0.4.17"}},
                        {id = "acme.app:terminal", kind = "ns.dependency", meta = {},
                            data = {component = "wippy/terminal", version = constraint}},
                    }),
                    ["wippy/test@0.4.17"] = package("wippy/test", "0.4.17", "b", {
                        {id = "wippy.test:terminal", kind = "ns.dependency", meta = {},
                            data = {component = "wippy/terminal", version = "*"}},
                    }),
                    ["wippy/terminal@0.4.5"] = package("wippy/terminal", "0.4.5", "c"),
                    ["wippy/terminal@0.4.6"] = package("wippy/terminal", "0.4.6", "d"),
                })
                local lists = 0
                artifacts.versions = function(_: string, _: integer): ({string}?, boolean?, string?)
                    lists = lists + 1; return {"0.4.6", "0.4.5"}, false, nil
                end
                local prepared, problem = plan.prepare(captured, 4,
                    request({action = "update", component = "acme/app", version = "2.0.0"}), artifacts)
                test.is_nil(problem); test.not_nil(prepared)
                if prepared then
                    local terminal = module_for(prepared.plan.modules, "wippy/terminal")
                    test.not_nil(terminal)
                    if terminal then
                        local kept = constraint == "*" or constraint == ">=0.4.0 <0.5.0"
                        test.eq(terminal.version, kept and "0.4.5" or "0.4.6")
                        test.eq(terminal.change, kept and "keep" or "update")
                        if kept then test.eq(lists, 0) end
                    end
                end
            end)
        end
        test.it("reselects an installed candidate when a later diamond constraint rejects it", function()
            local artifacts = source({
                ["acme/root@1.0.0"] = package("acme/root", "1.0.0", "a", {
                    {id = "acme.root:shared", kind = "ns.dependency", meta = {}, data = {component = "acme/shared", version = "*"}},
                    {id = "acme.root:z", kind = "ns.dependency", meta = {}, data = {component = "acme/z", version = "1.0.0"}},
                }),
                ["acme/z@1.0.0"] = package("acme/z", "1.0.0", "b", {
                    {id = "acme.z:shared", kind = "ns.dependency", meta = {}, data = {component = "acme/shared", version = ">=2.0.0"}},
                }),
                ["acme/shared@1.0.0"] = package("acme/shared", "1.0.0", "c", {
                    {id = "acme.shared:old", kind = "ns.dependency", meta = {}, data = {component = "acme/old", version = "1.0.0"}},
                }),
                ["acme/shared@2.0.0"] = package("acme/shared", "2.0.0", "d"),
                ["acme/old@1.0.0"] = package("acme/old", "1.0.0", "e"),
            })
            artifacts.versions = function(_: string, _: integer): ({string}?, boolean?, string?) return {"2.0.0", "1.0.0"}, false, nil end
            local resolved, problem = graph.resolve({{component = "acme/root", version = "1.0.0", parameters = {}}},
                artifacts, {["acme/shared"] = "1.0.0"})
            test.is_nil(problem); test.not_nil(resolved)
            if resolved then
                test.eq(#resolved.packages, 3)
                test.eq(resolved.packages[2].component, "acme/shared")
                test.eq(resolved.packages[2].version, "2.0.0")
            end
        end)
        test.it("uses runtime stable-release preference and does not backtrack a parent to satisfy its children", function()
            local artifacts = source({
                ["acme/app@1.0.0"] = package("acme/app", "1.0.0", "a"),
                ["acme/app@2.0.0-beta"] = package("acme/app", "2.0.0-beta", "b"),
                ["acme/app@2.0.0"] = package("acme/app", "2.0.0", "c", {
                    {id = "acme.app:child", kind = "ns.dependency", meta = {}, data = {component = "acme/child", version = "1.0.0"}},
                }),
            })
            artifacts.versions = function(name: string, _: integer): ({string}?, boolean?, string?)
                if name == "acme/app" then return {"2.0.0-beta", "1.0.0"}, false, nil end
                return {}, false, nil
            end
            local resolved, problem = graph.resolve({{component = "acme/app", version = ">=1.0.0 || >=2.0.0-beta", parameters = {}}}, artifacts)
            test.is_nil(problem); test.not_nil(resolved)
            if resolved then test.eq(resolved.packages[1].version, "1.0.0") end
            artifacts.versions = function(name: string, _: integer): ({string}?, boolean?, string?)
                if name == "acme/app" then return {"2.0.0", "1.0.0"}, false, nil end
                return {}, false, nil
            end
            -- Only the lower parent has a satisfiable closure. Runtime still
            -- chooses 2.0.0 and reports its missing child rather than downgrading.
            test.is_nil((graph.resolve({{component = "acme/app", version = "*", parameters = {}}}, artifacts)))
        end)
        test.it("reads the native host manifest through the declared environment module", function()
            local identity, problem = host_identity.read_host()
            test.is_nil(problem)
            test.not_nil(identity)
            if identity then
                test.eq(identity.native_module, "github.com/wippyai/bee/native")
                test.eq(identity.native_version, "v1.2.3")
                test.eq(identity.native_modules[identity.native_module], "v1.2.3")
                test.eq(identity.runtime_commit, "728b75942028080264aacbb16ef0420a0f8090b4")
            end
        end)
        test.it("measures a large policy closure without the message encoder limit", function()
            local entries: {inspect.Entry} = {}
            for index = 1, 200 do
                entries[index] = {id = "acme.large:policy_" .. tostring(index), kind = "security.policy",
                    meta = {}, data = {policy = {actions = {"registry.get"}, resources = {"acme.large:*"}, effect = "allow"}}}
            end
            local selected = request({action = "install", component = "acme/large", version = "1.0.0"})
            local prepared, problem = plan.prepare(state({}), 1, selected,
                source({["acme/large@1.0.0"] = package("acme/large", "1.0.0", "a", entries)}))
            test.is_nil(problem)
            test.not_nil(prepared)
            if not prepared then return end
            test.eq(#prepared.plan.policy_changes, 200)
            test.eq(#prepared.plan.digest, 64)
            entries[200].data = {policy = {actions = {"registry.apply"}, resources = {"acme.large:*"}, effect = "allow"}}
            local changed, changed_error = plan.prepare(state({}), 1, selected,
                source({["acme/large@1.0.0"] = package("acme/large", "1.0.0", "a", entries)}))
            test.is_nil(changed_error)
            test.not_nil(changed)
            if changed then test.eq(changed.plan.digest == prepared.plan.digest, false) end
        end)

        test.it("preserves bundled modules outside the dependency-root closure", function()
            local resident = {id = "bee.core:main", kind = "library.lua", registry = {owner = "bee/core", root = false}}
            -- A fresh embedded deployment has ownership but no persisted
            -- resolution. Its retained modules must not become removals or
            -- invented version selections in the first Hub plan.
            local captured = state({resident})
            local prepared, problem = plan.prepare(captured, 1,
                request({action = "install", component = "acme/app", version = "1.0.0"}),
                source({["acme/app@1.0.0"] = package("acme/app", "1.0.0", "a")}))
            test.is_nil(problem)
            test.not_nil(prepared)
            if prepared then
                local kept = module_for(prepared.plan.modules, "bee/core")
                test.not_nil(kept)
                if kept then test.eq(kept.change, "keep"); test.eq(kept.version, "") end
            end
            local known, known_problem = plan.prepare(state({resident}, {
                {name = "bee/core", version = "0.1.0-dev", source = "hub"},
            }), 1, request({action = "install", component = "acme/app", version = "1.0.0"}),
                source({["acme/app@1.0.0"] = package("acme/app", "1.0.0", "a")}))
            test.is_nil(known_problem)
            test.not_nil(known)
            if known then
                local kept = module_for(known.plan.modules, "bee/core")
                test.not_nil(kept)
                if kept then test.eq(kept.change, "keep"); test.eq(kept.version, "0.1.0-dev") end
            end
            local replacing = plan.prepare(captured, 1,
                request({action = "install", component = "bee/core", version = "0.2.0"}),
                source({["bee/core@0.2.0"] = package("bee/core", "0.2.0", "b")}))
            test.is_nil(replacing)
        end)
        test.it("removes departing root dependencies while keeping the resident host", function()
            local captured = state({
                root("acme/app", "1.0.0"),
                {id = "acme.app:lib", kind = "ns.dependency", registry = {owner = "acme/app", root = false},
                    data = {component = "acme/lib", version = "1.0.0"}},
                {id = "acme.lib:main", kind = "library.lua", registry = {owner = "acme/lib", root = false}},
                {id = "bee.core:main", kind = "library.lua", registry = {owner = "bee/core", root = false}},
            }, {{name = "acme/app", version = "1.0.0"}, {name = "acme/lib", version = "1.0.0"},
                {name = "bee/core", version = "0.1.0-dev", source = "hub"}})
            local prepared, problem = plan.prepare(captured, 2,
                request({action = "uninstall", component = "acme/app"}), source({}))
            test.is_nil(problem)
            test.not_nil(prepared)
            if prepared then
                for _, item in ipairs(prepared.plan.modules) do
                    test.eq(item.change, item.component == "bee/core" and "keep" or "remove")
                end
            end
        end)
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

        test.it("does not fetch host roots while preparing a Hub install", function()
            local prepared, problem = plan.prepare(state({
                {id = "bee:dependency_sync", kind = "ns.dependency", registry = {owner = "", root = true},
                    data = {component = "bee/sync", version = "0.1.0-dev"}},
            }, {{name = "bee/sync", version = "0.1.0-dev", source = "local"}}), 4,
                request({action = "install", component = "acme/app", version = "1.0.0"}),
                source({["acme/app@1.0.0"] = package("acme/app", "1.0.0", "a")}))
            test.is_nil(problem)
            test.not_nil(prepared)
        end)

        test.it("keeps a host-rooted shared dependency on Hub removal", function()
            local captured = state({
                root("acme/app", "1.0.0"),
                {id = "bee:dependency_shared", kind = "ns.dependency", registry = {owner = "", root = true},
                    data = {component = "acme/shared", version = "1.0.0"}},
                {id = "acme.app:shared", kind = "ns.dependency", registry = {owner = "acme/app", root = false},
                    data = {component = "acme/shared", version = "1.0.0"}},
                {id = "acme.shared:host_child", kind = "ns.dependency", registry = {owner = "acme/shared", root = false},
                    data = {component = "acme/host_child", version = "1.0.0"}},
            }, {{name = "acme/app", version = "1.0.0"}, {name = "acme/shared", version = "1.0.0"},
                {name = "acme/host_child", version = "1.0.0"}})
            local prepared, problem = plan.prepare(captured, 4,
                request({action = "uninstall", component = "acme/app"}), source({}))
            test.is_nil(problem)
            test.not_nil(prepared)
            if prepared then
                local app, shared = module_for(prepared.plan.modules, "acme/app"), module_for(prepared.plan.modules, "acme/shared")
                local host_child = module_for(prepared.plan.modules, "acme/host_child")
                test.not_nil(app); test.not_nil(shared); test.not_nil(host_child)
                if app then test.eq(app.change, "remove") end
                if shared then test.eq(shared.change, "keep") end
                if host_child then test.eq(host_child.change, "keep") end
            end
        end)

        test.it("refuses a direct host-managed target", function()
            local prepared, problem = plan.prepare(state({
                {id = "host.config:app", kind = "ns.dependency", registry = {owner = "", root = true},
                    data = {component = "acme/app", version = "1.0.0"}},
            }, {{name = "acme/app", version = "1.0.0", source = "local"}}), 4,
                request({action = "update", component = "acme/app", version = "1.1.0"}), source({}))
            test.is_nil(prepared)
            test.eq(problem, "component is managed by the host deployment")
        end)

        test.it("requires host selection before managing Bee components", function()
            local prepared, problem = plan.prepare(state({}), 1,
                request({action = "install", component = "bee/application", version = "0.2.0"}), source({}))
            test.is_nil(prepared)
            test.eq(problem, "Bee component management requires explicit host-selected roots")
        end)

        test.it("converts host-selected component roots while preserving third-party parameters", function()
            local selected = {id = "bee.deps:files", kind = "ns.dependency", meta = {independent = true}, registry = {owner = "bee/bee", root = true},
                data = {component = "bee/files", version = "1.0.0", parameters = {{name = "folder", value = "bee.env:files_root"}}}}
            local captured = state({selected, root("acme/app", "1.0.0"),},
                {{name = "bee/files", version = "1.0.0"}, {name = "acme/app", version = "1.0.0"}})
            local artifacts = source({
                ["bee/files@2.0.0"] = package("bee/files", "2.0.0", "a", {
                    {id = "bee.files:folder", kind = "ns.requirement", meta = {},
                        data = {targets = {{entry = "bee.files:main", path = ".folder"}}}},
                    {id = "bee.files:main", kind = "registry.entry", meta = {}, data = {}},
                }),
                ["acme/app@1.0.0"] = package("acme/app", "1.0.0", "b"),
            })
            local prepared, problem = plan.prepare(captured, 3,
                request({action = "update", component = "bee/files", version = "2.0.0",
                    parameters = {{name = "folder", value = "bee.env:files_root"}}}), artifacts)
            test.is_nil(problem); test.not_nil(prepared)
            if prepared then
                test.eq(prepared.plan.root_id, "bee.deps:files")
                test.not_nil(prepared.plan.conversion)
                local third = module_for(prepared.plan.modules, "acme/app")
                if third then test.eq(third.change, "keep") else test.not_nil(third) end
            end
            local removed, remove_error = plan.prepare(captured, 3,
                request({action = "uninstall", component = "bee/files"}), artifacts)
            test.is_nil(remove_error); test.not_nil(removed)
        end)
        for _, action in ipairs({"update", "uninstall"}) do
            test.it("protects the installed Hub from independent " .. action, function()
                local captured = state({
                    {id = "bee.deps:hub", kind = "ns.dependency", registry = {owner = "bee/bee", root = true},
                        data = {component = "bee/hub", version = "1.0.0"}},
                }, {{name = "bee/hub", version = "1.0.0"}})
                local raw: {[string]: unknown} = {action = action, component = "bee/hub"}
                if action == "update" then raw.version = "2.0.0" end
                local prepared, problem = plan.prepare(captured, 3, request(raw), source({}))
                test.is_nil(prepared)
                test.eq(problem, "protected boot/installer component cannot be " .. (action == "uninstall" and "removed" or "updated") .. " independently: bee/hub; required by bee.deps:hub")
            end)
        end

        test.it("refuses dangling requirement targets before publication", function()
            local prepared, problem = plan.prepare(state({}), 1,
                request({action = "install", component = "acme/app", version = "1.0.0"}),
                source({["acme/app@1.0.0"] = package("acme/app", "1.0.0", "a", {
                    {id = "acme.app:folder", kind = "ns.requirement", meta = {}, data = {default = "selected",
                        targets = {{entry = "acme.app:missing", path = ".folder"}}}},
                })}))
            test.is_nil(prepared)
            test.eq(problem, "requirement target does not resolve: acme.app:folder -> acme.app:missing")
        end)
        test.it("refuses removing an optional component needed by a third-party root", function()
            local captured = state({root("acme/app", "1.0.0"),
                {id = "bee.deps:files", kind = "ns.dependency", meta = {independent = true}, registry = {owner = "bee/bee", root = true},
                    data = {component = "bee/files", version = "1.0.0"}},
                {id = "acme.app:files", kind = "ns.dependency", registry = {owner = "acme/app"},
                    data = {component = "bee/files", version = "1.0.0"}},
            }, {{name = "acme/app", version = "1.0.0"}, {name = "bee/files", version = "1.0.0"}})
            local prepared, problem = plan.prepare(captured, 1, request({action = "uninstall", component = "bee/files"}), source({}))
            test.is_nil(prepared)
            test.eq(problem, "component is still required by acme/app")
        end)
        test.it("derives protection for the Hub dependency closure at plan time", function()
            local captured = state({
                {id = "bee.deps:hub", kind = "ns.dependency", registry = {owner = "", root = true},
                    data = {component = "bee/hub", version = "1.0.0"}},
                {id = "bee.deps:values", kind = "ns.dependency", meta = {independent = true}, registry = {owner = "", root = true},
                    data = {component = "bee/values", version = "1.0.0"}},
                {id = "bee.hub:values", kind = "ns.dependency", registry = {owner = "bee/hub"},
                    data = {component = "bee/values", version = "1.0.0"}},
            }, {{name = "bee/hub", version = "1.0.0"}, {name = "bee/values", version = "1.0.0"}})
            local prepared, problem = plan.prepare(captured, 1, request({action = "uninstall", component = "bee/values"}), source({}))
            test.is_nil(prepared)
            test.eq(problem, "protected boot/installer component cannot be removed independently: bee/values; required by bee.hub:values")
        end)
        test.it("refuses removing a target of a retained host requirement", function()
            local captured = state({
                {id = "bee.deps:files", kind = "ns.dependency", meta = {independent = true}, registry = {owner = "bee/bee", root = true},
                    data = {component = "bee/files", version = "1.0.0"}},
                {id = "bee.files:main", kind = "registry.entry", registry = {owner = "bee/files"}, data = {}},
                {id = "host:required_folder", kind = "ns.requirement", registry = {owner = ""},
                    data = {default = "selected", targets = {{entry = "bee.files:main", path = ".folder"}}}},
            }, {{name = "bee/files", version = "1.0.0"}})
            local prepared, problem = plan.prepare(captured, 1, request({action = "uninstall", component = "bee/files"}), source({}))
            test.is_nil(prepared)
            test.eq(problem, "requirement target does not resolve: host:required_folder -> bee.files:main")
        end)
        test.it("resolves local requirement target names in their declared namespace", function()
            local prepared, problem = plan.prepare(state({}), 1,
                request({action = "install", component = "acme/app", version = "1.0.0"}),
                source({["acme/app@1.0.0"] = package("acme/app", "1.0.0", "a", {
                    {id = "acme.app:folder", kind = "ns.requirement", meta = {}, data = {default = "workspace",
                        targets = {{entry = "main", path = ".folder"}}}},
                    {id = "acme.app:main", kind = "registry.entry", meta = {}, data = {}},
                })}))
            test.is_nil(problem)
            test.not_nil(prepared)
        end)
        test.it("keeps a converted optional root removed across self-update and refuses its resurrection", function()
            local captured = state({root("bee/bee", "1.0.0"),
                {id = "bee.deps:hub", kind = "ns.dependency", registry = {owner = "", root = true}, data = {component = "bee/hub", version = "1.0.0"}}}, {{name = "bee/bee", version = "1.0.0"}})
            local identity = binary_identity("github.com/wippyai/bee/native", "1.0.0")
            local selected = request({action = "update", component = "bee/bee", version = "2.0.0"})
            local safe, problem = plan.prepare(captured, 2, selected,
                source({["bee/bee@2.0.0"] = package("bee/bee", "2.0.0", "a", {identity})}), baked_identity("1.0.0"))
            test.is_nil(problem); test.not_nil(safe)
            local unsafe, unsafe_error = plan.prepare(captured, 2, selected,
                source({["bee/bee@2.0.0"] = package("bee/bee", "2.0.0", "a", {identity,
                    {id = "bee.deps:files", kind = "ns.dependency", meta = {}, data = {component = "bee/files", version = "1.0.0"}},
                })}), baked_identity("1.0.0"))
            test.is_nil(unsafe)
            test.eq(unsafe_error, "Bee self-update must leave component selection to host roots: bee.deps:files")
        end)
        test.it("converts an authored legacy composition during its first core self-update", function()
            local captured = state({root("bee/bee", "1.0.0"),
                {id = "bee.deps:files", kind = "ns.dependency", meta = {independent = true}, registry = {owner = "bee/bee", root = true},
                    data = {component = "bee/files", version = "1.0.0"}},
            }, {{name = "bee/bee", version = "1.0.0"}, {name = "bee/files", version = "1.0.0"}})
            local prepared, problem = plan.prepare(captured, 1, request({action = "update", component = "bee/bee", version = "2.0.0"}),
                source({["bee/bee@2.0.0"] = package("bee/bee", "2.0.0", "a", {binary_identity("github.com/wippyai/bee/native", "1.0.0")}),
                    ["bee/files@1.0.0"] = package("bee/files", "1.0.0", "b")}), baked_identity("1.0.0"))
            test.is_nil(problem); test.not_nil(prepared)
            if prepared then test.not_nil(prepared.plan.conversion) end
        end)
        test.it("updates the core while retaining independent component versions and parameters", function()
            local captured = state({
                root("bee/bee", "1.0.0"),
                {id = "bee.deps:files", kind = "ns.dependency", meta = {independent = true}, registry = {owner = "", root = true},
                    data = {component = "bee/files", version = "1.5.0", parameters = {{name = "folder", value = "selected"}}}},
            }, {{name = "bee/bee", version = "1.0.0"}, {name = "bee/files", version = "1.5.0"}})
            local prepared, problem = plan.prepare(captured, 2, request({action = "update", component = "bee/bee", version = "2.0.0"}),
                source({["bee/bee@2.0.0"] = package("bee/bee", "2.0.0", "a", {binary_identity("github.com/wippyai/bee/native", "1.0.0")}),
                    ["bee/files@1.5.0"] = package("bee/files", "1.5.0", "b", {
                        {id = "bee.files:folder", kind = "ns.requirement", meta = {}, data = {targets = {{entry = "main", path = ".folder"}}}},
                        {id = "bee.files:main", kind = "registry.entry", meta = {}, data = {}},
                    })}), baked_identity("1.0.0"))
            test.is_nil(problem); test.not_nil(prepared)
            if prepared then
                local files = module_for(prepared.plan.modules, "bee/files")
                test.not_nil(files)
                if files then test.eq(files.change, "keep"); test.eq(files.version, "1.5.0"); test.eq(files.requirements.requirements[1].selected, "selected") end
            end
        end)
        test.it("refuses self-update that resets an independently selected version", function()
            local selected_root = {id = "bee.deps:files", kind = "ns.dependency", registry = {owner = "", root = true},
                data = {component = "bee/files", version = "1.5.0"}}
            local captured = state({selected_root, root("bee/bee", "1.0.0")},
                {{name = "bee/bee", version = "1.0.0"}, {name = "bee/files", version = "1.5.0"}})
            local prepared, problem = plan.prepare(captured, 2, request({action = "update", component = "bee/bee", version = "2.0.0"}),
                source({["bee/bee@2.0.0"] = package("bee/bee", "2.0.0", "a", {
                    {id = "bee.deps:files", kind = "ns.dependency", meta = {}, data = {component = "bee/files", version = "2.0.0"}},
                })}), baked_identity("1.0.0"))
            test.is_nil(prepared)
            test.eq(problem, "Bee self-update must leave component selection to host roots: bee.deps:files")
        end)

        test.it("refuses self-update that replaces the active Hub installer code", function()
            local captured = state({root("bee/bee", "1.0.0"),
                {id = "bee.deps:hub", kind = "ns.dependency", registry = {owner = "bee/bee", root = true},
                    data = {component = "bee/hub", version = "1.0.0"}},
                {id = "bee.hub:plan", kind = "library.lua", registry = {owner = "bee/hub"}, data = {source = "return {}"}},
            }, {{name = "bee/bee", version = "1.0.0"}, {name = "bee/hub", version = "1.0.0"}})
            local prepared, problem = plan.prepare(captured, 3, request({action = "update", component = "bee/bee", version = "2.0.0"}),
                source({["bee/bee@2.0.0"] = package("bee/bee", "2.0.0", "a", {
                    {id = "bee.deps:hub", kind = "ns.dependency", meta = {}, data = {component = "bee/hub", version = "2.0.0"}},
                }), ["bee/hub@2.0.0"] = package("bee/hub", "2.0.0", "b", {
                    {id = "bee.hub:plan", kind = "library.lua", meta = {}, data = {source = "return {changed = true}"}},
                })}), baked_identity("1.0.0"))
            test.is_nil(prepared)
            test.eq(problem, "Bee self-update must leave component selection to host roots: bee.deps:hub")
        end)

        test.it("creates the first standalone selection instead of updating an absent entry", function()
            local installed = state({}, {{name = "bee/bee", version = "0.1.0", source = "hub"}})
            installed.resolution = {modules = {{name = "bee/bee", version = "0.1.0", source = "hub"}},
                lock = {root_module = "bee/bee", modules = {{name = "bee/bee", version = "0.1.0"}}}}
            local prepared, problem = plan.prepare(installed, 12,
                request({action = "update", component = "bee/bee", version = "0.2.0"}),
                source({["bee/bee@0.2.0"] = package("bee/bee", "0.2.0", "a", {
                    binary_identity("github.com/wippyai/bee/native", "1.0.0"),
                })}), baked_identity("1.0.0"))
            test.is_nil(problem)
            test.not_nil(prepared)
            if prepared then
                test.eq(prepared.plan.root_id, assert(plan.root_id("bee/bee")))
                test.eq(prepared.plan.root_operation, "create")
                test.eq(#prepared.installed.roots, 0)
            end
        end)

        test.it("refuses a first standalone selection whose destination is occupied", function()
            local installed = state({{id = assert(plan.root_id("bee/bee")), kind = "registry.entry",
                registry = {owner = "", root = false}, data = {}}})
            installed.resolution = {modules = {{name = "bee/bee", version = "0.1.0", source = "hub"}},
                lock = {root_module = "bee/bee", modules = {{name = "bee/bee", version = "0.1.0"}}}}
            local prepared, problem = plan.prepare(installed, 12,
                request({action = "update", component = "bee/bee", version = "0.2.0"}),
                source({["bee/bee@0.2.0"] = package("bee/bee", "0.2.0", "a", {
                    binary_identity("github.com/wippyai/bee/native", "1.0.0"),
                })}), baked_identity("1.0.0"))
            test.is_nil(prepared)
            test.eq(problem, "dependency destination is already occupied")
        end)

        test.it("updates the resident standalone selection while preserving parameters", function()
            local selection = root("bee/bee", "0.2.0")
            selection.data = {component = "bee/bee", version = "0.2.0", parameters = {{name = "setting", value = "kept"}}}
            local installed = state({selection})
            installed.resolution = {modules = {{name = "bee/bee", version = "0.2.0", source = "hub"}},
                lock = {root_module = "bee/bee", modules = {{name = "bee/bee", version = "0.1.0"}}}}
            local prepared, problem = plan.prepare(installed, 13,
                request({action = "update", component = "bee/bee", version = "0.3.0",
                    parameters = {{name = "setting", value = "kept"}}}),
                source({["bee/bee@0.3.0"] = package("bee/bee", "0.3.0", "a", {
                    binary_identity("github.com/wippyai/bee/native", "1.0.0"),
                    {id = "bee:setting", kind = "ns.requirement", meta = {},
                        data = {targets = {{entry = "bee.env:binary_identity", path = ".data.setting"}}}},
                }, {requirements = {{id = "bee:setting", has_default = false, has_selected = false,
                    targets = {{entry = "bee.env:binary_identity", path = ".data.setting"}}}}, missing = {"bee:setting"}})}), baked_identity("1.0.0"))
            test.is_nil(problem)
            test.not_nil(prepared)
            if prepared then
                test.eq(prepared.plan.root_id, selection.id)
                test.eq(prepared.plan.root_operation, "update")
                test.eq(#prepared.installed.roots, 1)
                test.eq(prepared.plan.request.parameters[1].value, "kept")
            end
            test.is_nil((plan.prepare(installed, 13,
                request({action = "update", component = "bee/bee", version = "0.3.0"}), source({}), baked_identity("1.0.0"))))
        end)

        test.it("updates the existing Bee deployment root and resolves its pack closure", function()
            local deployment = {id = "bee:deployment", kind = "ns.dependency", registry = {owner = "", root = true},
                data = {component = "bee/bee", version = "0.1.0", parameters = {}}}
            local application = {id = "bee:dependency_application", kind = "ns.dependency", registry = {owner = "bee/bee", root = true},
                data = {component = "bee/application", version = "0.1.0"}}
            local installed = state({deployment, application, root("acme/app", "1.0.0")}, {
                {name = "bee/bee", version = "0.1.0", source = "hub"},
                {name = "bee/application", version = "0.1.0", source = "hub"},
                {name = "acme/app", version = "1.0.0", source = "hub"},
            })
            local prepared, problem = plan.prepare(installed, 12,
                request({action = "update", component = "bee/bee", version = "0.2.0"}),
                source({
                    ["bee/bee@0.2.0"] = package("bee/bee", "0.2.0", "a", {
                        {id = "bee:dependency_application", kind = "ns.dependency", meta = {},
                            data = {component = "bee/application", version = "0.2.0"}},
                        binary_identity("github.com/wippyai/bee/native", "v0.0.0-20260926183503-c0d6585b5fd1"),
                    }),
                    ["bee/application@0.2.0"] = package("bee/application", "0.2.0", "b"),
                    ["acme/app@1.0.0"] = package("acme/app", "1.0.0", "c"),
                }), baked_identity("v0.0.0-20260926183503-c0d6585b5fd1"))
            test.is_nil(problem)
            test.not_nil(prepared)
            if prepared then
                test.eq(prepared.plan.root_id, "bee:deployment")
                test.eq(prepared.plan.root_operation, "update")
                local bee, application, third_party = module_for(prepared.plan.modules, "bee/bee"),
                    module_for(prepared.plan.modules, "bee/application"), module_for(prepared.plan.modules, "acme/app")
                test.not_nil(bee); test.not_nil(application); test.not_nil(third_party)
                if bee then test.eq(bee.change, "update") end
                if application then test.eq(application.change, "update") end
                if third_party then test.eq(third_party.change, "keep") end
            end
        end)

        test.it("checks target packs against host binary facts rather than live root metadata", function()
            local deployment = {id = "bee:deployment", kind = "ns.dependency", registry = {owner = "", root = true},
                data = {component = "bee/bee", version = "0.1.0", parameters = {}}}
            local current = "v0.0.0-20260926183503-c0d6585b5fd1"
            local identity = binary_identity("github.com/wippyai/bee/native/launch", "v0.0.0-20260925183503-c0d6585b5fd1")
            identity.registry = {owner = "bee/bee"}
            local target_identity = binary_identity("github.com/wippyai/bee/native/launch", current)
            target_identity.registry = nil
            local prepared, problem = plan.prepare(state({deployment, identity}, {
                {name = "bee/bee", version = "0.1.0", source = "hub"},
            }), 12, request({action = "update", component = "bee/bee", version = "0.2.0"}),
                source({["bee/bee@0.2.0"] = package("bee/bee", "0.2.0", "a", {target_identity})}), baked_identity(current))
            test.is_nil(problem)
            test.not_nil(prepared)
        end)

        test.it("refuses a Bee pack closure that requires a newer native binary", function()
            local deployment = {id = "bee:deployment", kind = "ns.dependency", registry = {owner = "", root = true},
                data = {component = "bee/bee", version = "0.1.0", parameters = {}}}
            local current = "v0.0.0-20260926183503-c0d6585b5fd1"
            local required = "v0.0.0-20260928183503-c0d6585b5fd1"
            local root_package = package("bee/bee", "0.2.0", "d", {
                {id = "bee:definition", kind = "ns.definition", meta = {native_requirements = {
                    {package = "github.com/wippyai/bee/native/launch", version = required}}}, data = {}},
                binary_identity("github.com/wippyai/bee/native/launch", current),
            })
            local installed = state({deployment, binary_identity("github.com/wippyai/bee/native/launch", current)}, {
                {name = "bee/bee", version = "0.1.0", source = "local"},
            })
            local prepared, problem = plan.prepare(installed, 12,
                request({action = "update", component = "bee/bee", version = "0.2.0"}),
                source({["bee/bee@0.2.0"] = root_package}), baked_identity(current))
            test.is_nil(prepared)
            test.eq(problem, "needs a newer Bee binary: bee/bee requires native component github.com/wippyai/bee/native/launch v0.0.0-20260928183503-c0d6585b5fd1; this binary has v0.0.0-20260926183503-c0d6585b5fd1")
        end)

        test.it("accepts a Bee pack closure within the baked native manifest", function()
            local deployment = {id = "bee:deployment", kind = "ns.dependency", registry = {owner = "", root = true},
                data = {component = "bee/bee", version = "0.1.0", parameters = {}}}
            local current = "v0.0.0-20260926183503-c0d6585b5fd1"
            local root_package = package("bee/bee", "0.2.0", "e", {
                {id = "bee:definition", kind = "ns.definition", meta = {native_requirements = {
                    {package = "github.com/wippyai/bee/native/launch", version = current}}}, data = {}},
                binary_identity("github.com/wippyai/bee/native/launch", current),
            })
            local installed = state({deployment, binary_identity("github.com/wippyai/bee/native/launch", current)}, {
                {name = "bee/bee", version = "0.1.0", source = "local"},
            })
            local prepared, problem = plan.prepare(installed, 12,
                request({action = "update", component = "bee/bee", version = "0.2.0"}),
                source({["bee/bee@0.2.0"] = root_package}), baked_identity(current))
            test.is_nil(problem)
            test.not_nil(prepared)
        end)

        test.it("refuses a Bee root pack built for a newer native manifest", function()
            local deployment = {id = "bee:deployment", kind = "ns.dependency", registry = {owner = "", root = true},
                data = {component = "bee/bee", version = "0.1.0", parameters = {}}}
            local current = "v0.0.0-20260926183503-c0d6585b5fd1"
            local target = "v0.0.0-20260928183503-c0d6585b5fd1"
            local root_package = package("bee/bee", "0.2.0", "d", {
                binary_identity("github.com/wippyai/bee/native/launch", target),
            })
            local installed = state({deployment, binary_identity("github.com/wippyai/bee/native/launch", current)}, {
                {name = "bee/bee", version = "0.1.0", source = "hub"},
            })
            local prepared, problem = plan.prepare(installed, 12,
                request({action = "update", component = "bee/bee", version = "0.2.0"}),
                source({["bee/bee@0.2.0"] = root_package}), baked_identity(current))
            test.is_nil(prepared)
            test.eq(problem, "needs a newer Bee binary: bee/bee pack set requires native component github.com/wippyai/bee/native/launch v0.0.0-20260928183503-c0d6585b5fd1; this binary has v0.0.0-20260926183503-c0d6585b5fd1")
        end)

        test.it("fails closed when host binary facts are unavailable", function()
            local scope, scope_error = security.named_scope("tests.hub.plan:without_native")
            if not scope then error(tostring(scope_error)) end
            local executor, executor_error = funcs.new():with_scope(scope)
            if not executor then error(tostring(executor_error)) end
            local reply, call_error = executor:call("tests.hub.plan:missing_native_probe", {})
            test.is_nil(call_error)
            local result = bounds.object(reply)
            test.not_nil(result)
            if result then
                test.eq(result.refused, true)
                test.eq(result.message, "needs a newer Bee binary: running binary native manifest is unavailable")
            end
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

        test.it("lists the security policies an update and an uninstall add, replace and remove", function()
            local function policy(id: string, owner: string, actions: {string}, resources: unknown): {[string]: unknown}
                return {id = id, kind = "security.policy", registry = {owner = owner, root = false},
                    data = {policy = {actions = actions, resources = resources, effect = "allow"}}}
            end
            local installed = state({
                root("acme/app", "1.0.0"),
                root("acme/other", "1.0.0"),
                policy("acme.app:reader", "acme/app", {"fs.get"}, {"acme.app:files"}),
                policy("acme.app:legacy", "acme/app", {"registry.get"}, "*"),
                policy("acme.other:reader", "acme/other", {"fs.get"}, {"acme.other:files"}),
            }, {
                {name = "acme/app", version = "1.0.0", source = "hub"},
                {name = "acme/other", version = "1.0.0", source = "hub"},
            })
            local artifacts = source({
                ["acme/app@1.1.0"] = package("acme/app", "1.1.0", "a", {
                    {id = "acme.app:reader", kind = "security.policy", meta = {},
                        data = {policy = {actions = {"fs.get", "fs.list"}, resources = {"acme.app:files"}, effect = "allow"}}},
                    {id = "acme.app:writer", kind = "security.policy.expr", meta = {},
                        data = {policy = {actions = {"fs.put"}, resources = "*", expression = "true", effect = "allow"}}},
                }),
                ["acme/other@1.0.0"] = package("acme/other", "1.0.0", "b", {
                    {id = "acme.other:reader", kind = "security.policy", meta = {},
                        data = {policy = {actions = {"fs.get"}, resources = {"acme.other:files"}, effect = "allow"}}},
                }),
            })
            local update, update_problem = plan.prepare(installed, 4,
                request({action = "update", component = "acme/app", version = "1.1.0"}), artifacts)
            test.is_nil(update_problem)
            test.not_nil(update)
            if update then
                local changes = update.plan.policy_changes
                test.eq(#changes, 3)
                test.eq(changes[1].id, "acme.app:legacy"); test.eq(changes[1].change, "remove")
                test.eq(changes[1].resources[1], "*"); test.eq(changes[1].actions[1], "registry.get")
                test.eq(changes[2].id, "acme.app:reader"); test.eq(changes[2].change, "update")
                test.eq(changes[2].actions[2], "fs.list"); test.eq(changes[2].component, "acme/app")
                test.eq(changes[3].id, "acme.app:writer"); test.eq(changes[3].change, "add")
                test.is_true(changes[3].expression)
            end
            local uninstall, uninstall_problem = plan.prepare(installed, 4,
                request({action = "uninstall", component = "acme/app"}), artifacts)
            test.is_nil(uninstall_problem)
            test.not_nil(uninstall)
            if uninstall then
                local changes = uninstall.plan.policy_changes
                test.eq(#changes, 2)
                test.eq(changes[1].id, "acme.app:legacy"); test.eq(changes[1].change, "remove")
                test.eq(changes[2].id, "acme.app:reader"); test.eq(changes[2].change, "remove")
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
