-- MIT. Focused plan test cases.
local test = require("test")
local plan = require("plan")
local inspect = require("inspect")
local requirements = require("requirements")
local support = require("support")
local root = support.root
local state = support.state
local binary_identity = support.binary_identity
local baked_identity = support.baked_identity
local package = support.package
local source = support.source
local request = support.request
local module_for = support.module_for
local M = {}
function M.define()
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
        test.eq(problem, "protected boot/installer component cannot be updated independently: acme/app; required by host.config:app")
    end)

    test.it("admits an unselected package without inferring host ownership from its brand", function()
        local prepared, problem = plan.prepare(state({}), 1,
            request({action = "install", component = "bee/application", version = "0.2.0"}), source({["bee/application@0.2.0"] = package("bee/application", "0.2.0", "a")}))
        test.is_nil(problem)
        test.not_nil(prepared)
    end)

    test.it("converts host-selected component roots while preserving third-party parameters", function()
        local selected = {id = "bee.deps:files", kind = "ns.dependency", meta = {type = "bee.component_selection", independent = true}, registry = {owner = "bee/bee", root = true},
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
                {id = "bee.deps:hub", kind = "ns.dependency", meta = {type = "bee.component_selection"}, registry = {owner = "bee/bee", root = true},
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
            {id = "bee.deps:files", kind = "ns.dependency", meta = {type = "bee.component_selection", independent = true}, registry = {owner = "bee/bee", root = true},
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
            {id = "bee.deps:hub", kind = "ns.dependency", meta = {type = "bee.component_selection"}, registry = {owner = "", root = true},
                data = {component = "bee/hub", version = "1.0.0"}},
            {id = "bee.deps:values", kind = "ns.dependency", meta = {type = "bee.component_selection", independent = true}, registry = {owner = "", root = true},
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
            {id = "bee.deps:files", kind = "ns.dependency", meta = {type = "bee.component_selection", independent = true}, registry = {owner = "bee/bee", root = true},
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
            {id = "bee.deps:hub", kind = "ns.dependency", meta = {type = "bee.component_selection"}, registry = {owner = "", root = true}, data = {component = "bee/hub", version = "1.0.0"}}}, {{name = "bee/bee", version = "1.0.0"}})
        local identity = binary_identity("github.com/wippyai/bee/native", "1.0.0")
        local selected = request({action = "update", component = "bee/bee", version = "2.0.0"})
        local safe, problem = plan.prepare(captured, 2, selected,
            source({["bee/bee@2.0.0"] = package("bee/bee", "2.0.0", "a", {identity}),
                ["bee/hub@1.0.0"] = package("bee/hub", "1.0.0", "b")}), baked_identity("1.0.0"))
        test.is_nil(problem); test.not_nil(safe)
        local unsafe, unsafe_error = plan.prepare(captured, 2, selected,
            source({["bee/bee@2.0.0"] = package("bee/bee", "2.0.0", "a", {identity,
                {id = "bee.deps:files", kind = "ns.dependency", meta = {type = "bee.component_selection"}, data = {component = "bee/files", version = "1.0.0"}},
            })}), baked_identity("1.0.0"))
        test.is_nil(unsafe)
        test.eq(unsafe_error, "Bee self-update must leave component selection to host roots: bee.deps:files")
    end)
    test.it("converts an authored legacy composition during its first core self-update", function()
        local captured = state({root("bee/bee", "1.0.0"),
            {id = "bee.deps:files", kind = "ns.dependency", meta = {type = "bee.component_selection", independent = true}, registry = {owner = "bee/bee", root = true},
                data = {component = "bee/files", version = "1.0.0"}},
        }, {{name = "bee/bee", version = "1.0.0"}, {name = "bee/files", version = "1.0.0"}})
        local prepared, problem = plan.prepare(captured, 1, request({action = "update", component = "bee/bee", version = "2.0.0"}),
            source({["bee/bee@2.0.0"] = package("bee/bee", "2.0.0", "a", {binary_identity("github.com/wippyai/bee/native", "1.0.0")}),
                ["bee/files@1.0.0"] = package("bee/files", "1.0.0", "b")}), baked_identity("1.0.0"))
        test.is_nil(problem); test.not_nil(prepared)
        if prepared then test.not_nil(prepared.plan.conversion) end
    end)
    test.it("updates the core and selected components together while retaining parameters", function()
        local captured = state({
            root("bee/bee", "1.0.0"),
            {id = "bee.deps:files", kind = "ns.dependency", meta = {type = "bee.component_selection", independent = true}, registry = {owner = "", root = true},
                data = {component = "bee/files", version = "1.5.0", parameters = {{name = "folder", value = "selected"}}}},
        }, {{name = "bee/bee", version = "1.0.0"}, {name = "bee/files", version = "1.5.0"}})
        local prepared, problem = plan.prepare(captured, 2, request({action = "update", component = "bee/bee", version = "2.0.0"}),
            source({["bee/bee@2.0.0"] = package("bee/bee", "2.0.0", "a", {binary_identity("github.com/wippyai/bee/native", "1.0.0")}),
                ["bee/files@2.0.0"] = package("bee/files", "2.0.0", "b", {
                    {id = "bee.files:folder", kind = "ns.requirement", meta = {}, data = {targets = {{entry = "main", path = ".folder"}}}},
                    {id = "bee.files:main", kind = "registry.entry", meta = {}, data = {}},
                })}), baked_identity("1.0.0"))
        test.is_nil(problem); test.not_nil(prepared)
        if prepared then
            local files = module_for(prepared.plan.modules, "bee/files")
            test.not_nil(files)
            if files then test.eq(files.change, "update"); test.eq(files.version, "2.0.0"); test.eq(files.requirements.requirements[1].selected, "selected") end
        end
    end)
    for _, independent in ipairs({false, true}) do
        test.it("updates host-selected Settings with the core; independent=" .. tostring(independent), function()
            local captured = state({root("bee/bee", "1.0.0"), root("acme/app", "1.0.0"),
                {id = "bee.deps:settings", kind = "ns.dependency", meta = {type = "bee.component_selection", independent = independent},
                    registry = {owner = "", root = true}, data = {component = "bee/settings", version = "1.0.0"}},
            }, {{name = "bee/bee", version = "1.0.0"}, {name = "bee/settings", version = "1.0.0"},
                {name = "acme/app", version = "1.0.0"}})
            local prepared, problem = plan.prepare(captured, 2,
                request({action = "update", component = "bee/bee", version = "2.0.0"}), source({
                    ["bee/bee@2.0.0"] = package("bee/bee", "2.0.0", "a", {binary_identity("github.com/wippyai/bee/native", "1.0.0")}),
                    ["bee/settings@2.0.0"] = package("bee/settings", "2.0.0", "b"),
                    ["acme/app@1.0.0"] = package("acme/app", "1.0.0", "c"),
                    ["acme/app@2.0.0"] = package("acme/app", "2.0.0", "d"),
                }), baked_identity("1.0.0"))
            test.is_nil(problem); test.not_nil(prepared)
            if prepared then
                local settings, third_party = module_for(prepared.plan.modules, "bee/settings"), module_for(prepared.plan.modules, "acme/app")
                test.not_nil(settings); test.not_nil(third_party)
                if settings then test.eq(settings.version, "2.0.0"); test.eq(settings.change, "update") end
                if third_party then test.eq(third_party.version, "1.0.0"); test.eq(third_party.change, "keep") end
                test.is_nil(module_for(prepared.plan.modules, "bee/files"))
                test.is_true(prepared.plan.ready)
            end
        end)
    end
    test.it("updates the Settings prerelease during first host-root conversion", function()
        local captured = state({root("bee/bee", "0.1.0-0.boot.dev"),
            {id = "bee.deps:settings", kind = "ns.dependency", meta = {type = "bee.component_selection"},
                registry = {owner = "bee/bee", root = true},
                data = {component = "bee/settings", version = "0.1.0-dev"}},
        }, {{name = "bee/bee", version = "0.1.0-0.boot.dev"}, {name = "bee/settings", version = "0.1.0-dev"}})
        local target = "0.1.0-ownerjourney.1"
        local prepared, problem = plan.prepare(captured, 0,
            request({action = "update", component = "bee/bee", version = target}), source({
                ["bee/bee@" .. target] = package("bee/bee", target, "a", {binary_identity("github.com/wippyai/bee/native", "1.0.0")}),
                ["bee/settings@" .. target] = package("bee/settings", target, "b"),
                ["bee/settings@0.1.0-dev"] = package("bee/settings", "0.1.0-dev", "c"),
            }), baked_identity("1.0.0"))
        test.is_nil(problem); test.not_nil(prepared)
        if prepared then
            test.not_nil(prepared.plan.conversion)
            local settings = assert(module_for(prepared.plan.modules, "bee/settings"))
            test.eq(settings.version, target); test.eq(settings.change, "update")
        end
    end)
    for _, pinned in ipairs({false, true}) do
        test.it("lists retained component reason; pinned=" .. tostring(pinned), function()
            local resident: {unknown} = {root("bee/bee", "1.0.0"), root("acme/app", "1.0.0"),
                {id = "bee.deps:settings", kind = "ns.dependency", meta = {type = "bee.component_selection"}, registry = {owner = "", root = true},
                    data = {component = "bee/settings", version = "1.0.0"}}}
            local dependencies: {inspect.Entry} = {}
            if pinned then
                local dependency = {id = "acme.app:settings", kind = "ns.dependency", meta = {},
                    data = {component = "bee/settings", version = "1.0.0"}, registry = {owner = "acme/app"}}
                resident[#resident + 1] = dependency
                dependencies[#dependencies + 1] = dependency
            end
            local prepared, problem = plan.prepare(state(resident, {{name = "bee/bee", version = "1.0.0"},
                {name = "bee/settings", version = "1.0.0"}, {name = "acme/app", version = "1.0.0"}}), 2,
                request({action = "update", component = "bee/bee", version = "2.0.0"}), source({
                    ["bee/bee@2.0.0"] = package("bee/bee", "2.0.0", "a", {binary_identity("github.com/wippyai/bee/native", "1.0.0")}),
                    ["bee/settings@1.0.0"] = package("bee/settings", "1.0.0", "b"),
                    ["bee/settings@2.0.0"] = package("bee/settings", "2.0.0", "c", pinned and {} or {
                        {id = "bee.settings:definition", kind = "ns.definition", data = {}, meta = {native_requirements = {
                            {package = "github.com/wippyai/bee/native", version = "3.0.0"}}}}}),
                    ["acme/app@1.0.0"] = package("acme/app", "1.0.0", "d", dependencies),
                }), baked_identity("1.0.0"))
            test.is_nil(problem); test.not_nil(prepared)
            if prepared then
                local settings = module_for(prepared.plan.modules, "bee/settings")
                test.not_nil(settings)
                if settings then test.eq(settings.change, "keep"); test.not_nil(settings.reason) end
            end
        end)
    end
    test.it("retains a third-party wildcard root when a newer Bee component requires replacing it", function()
        local captured = state({root("bee/bee", "1.0.0"), root("acme/app", "*"),
            {id = "bee.deps:settings", kind = "ns.dependency", meta = {type = "bee.component_selection"}, registry = {owner = "", root = true},
                data = {component = "bee/settings", version = "1.0.0"}},
        }, {{name = "bee/bee", version = "1.0.0"}, {name = "bee/settings", version = "1.0.0"},
            {name = "acme/app", version = "1.0.0"}})
        local prepared, problem = plan.prepare(captured, 1,
            request({action = "update", component = "bee/bee", version = "2.0.0"}), source({
                ["bee/bee@2.0.0"] = package("bee/bee", "2.0.0", "a", {binary_identity("github.com/wippyai/bee/native", "1.0.0")}),
                ["bee/settings@1.0.0"] = package("bee/settings", "1.0.0", "b"),
                ["bee/settings@2.0.0"] = package("bee/settings", "2.0.0", "c", {
                    {id = "bee.settings:thirdparty", kind = "ns.dependency", meta = {}, data = {component = "acme/app", version = "2.0.0"}}}),
                ["acme/app@1.0.0"] = package("acme/app", "1.0.0", "d"),
                ["acme/app@2.0.0"] = package("acme/app", "2.0.0", "e"),
            }), baked_identity("1.0.0"))
        test.is_nil(problem); test.not_nil(prepared)
        if prepared then
            local settings, third_party = module_for(prepared.plan.modules, "bee/settings"), module_for(prepared.plan.modules, "acme/app")
            test.not_nil(settings); test.not_nil(third_party)
            if settings then
                test.eq(settings.change, "keep")
                test.eq(settings.reason, "bee/settings requires third-party root acme/app 2.0.0")
            end
            if third_party then test.eq(third_party.change, "keep"); test.eq(third_party.version, "1.0.0") end
        end
    end)
    test.it("lists a selected component whose advertised update artifact is unavailable", function()
        local captured = state({root("bee/bee", "1.0.0"),
            {id = "bee.deps:settings", kind = "ns.dependency", meta = {type = "bee.component_selection"}, registry = {owner = "", root = true},
                data = {component = "bee/settings", version = "1.0.0"}},
        }, {{name = "bee/bee", version = "1.0.0"}, {name = "bee/settings", version = "1.0.0"}})
        local artifacts = source({
            ["bee/bee@2.0.0"] = package("bee/bee", "2.0.0", "a", {binary_identity("github.com/wippyai/bee/native", "1.0.0")}),
            ["bee/settings@1.0.0"] = package("bee/settings", "1.0.0", "b"),
        })
        artifacts.versions = function(_: string, _: integer): ({string}?, boolean?, string?) return {"2.0.0"}, false, nil end
        local prepared, problem = plan.prepare(captured, 1,
            request({action = "update", component = "bee/bee", version = "2.0.0"}), artifacts, baked_identity("1.0.0"))
        test.is_nil(problem); test.not_nil(prepared)
        if prepared then
            local settings = module_for(prepared.plan.modules, "bee/settings")
            test.not_nil(settings)
            if settings then test.eq(settings.change, "keep"); test.eq(settings.reason, "missing artifact") end
        end
    end)
    test.it("selects a coordinated prerelease closure without retaining its old dependency pins", function()
        local captured = state({root("bee/bee", "1.0.0"),
            {id = "bee.deps:settings", kind = "ns.dependency", meta = {type = "bee.component_selection"}, registry = {owner = "", root = true},
                data = {component = "bee/settings", version = "1.0.0"}},
            {id = "bee.deps:application", kind = "ns.dependency", meta = {type = "bee.component_selection"}, registry = {owner = "", root = true},
                data = {component = "bee/application", version = "1.0.0"}},
        }, {{name = "bee/bee", version = "1.0.0"}, {name = "bee/settings", version = "1.0.0"},
            {name = "bee/application", version = "1.0.0"}})
        local target = "2.0.0-beta.1"
        local prepared, problem = plan.prepare(captured, 1,
            request({action = "update", component = "bee/bee", version = target}), source({
                ["bee/bee@" .. target] = package("bee/bee", target, "a", {binary_identity("github.com/wippyai/bee/native", "1.0.0")}),
                ["bee/settings@" .. target] = package("bee/settings", target, "b", {
                    {id = "bee.settings:application", kind = "ns.dependency", meta = {}, data = {component = "bee/application", version = target}}}),
                ["bee/application@" .. target] = package("bee/application", target, "c"),
            }), baked_identity("1.0.0"))
        test.is_nil(problem); test.not_nil(prepared)
        if prepared then
            for _, item in ipairs(prepared.plan.modules) do test.eq(item.version, target); test.eq(item.change, "update") end
        end
    end)
    test.it("selects the newest core-compatible release and rejects a removed dependency", function()
        local captured = state({root("bee/bee", "1.0.0"),
            {id = "bee.deps:settings", kind = "ns.dependency", meta = {type = "bee.component_selection"}, registry = {owner = "", root = true},
                data = {component = "bee/settings", version = "*"}},
        }, {{name = "bee/bee", version = "1.0.0"}, {name = "bee/settings", version = "1.0.0"}})
        captured.resolution = {modules = {{name = "bee/bee", version = "1.0.0"}, {name = "bee/settings", version = "1.0.0"}},
            lock = {root_module = "bee/bee", modules = {{name = "bee/bee", version = "1.0.0"},
                {name = "bee/settings", version = "1.0.0"}, {name = "bee/files", version = "1.0.0"}}}}
        local artifacts = source({
            ["bee/bee@2.0.0"] = package("bee/bee", "2.0.0", "a", {binary_identity("github.com/wippyai/bee/native", "1.0.0")}),
            ["bee/settings@1.0.0"] = package("bee/settings", "1.0.0", "b"),
            ["bee/settings@1.5.0"] = package("bee/settings", "1.5.0", "c"),
            ["bee/settings@2.0.0"] = package("bee/settings", "2.0.0", "d", {
                {id = "bee.settings:files", kind = "ns.dependency", meta = {}, data = {component = "bee/files", version = "1.0.0"}}}),
            ["bee/settings@3.0.0"] = package("bee/settings", "3.0.0", "e", {
                {id = "bee.settings:core", kind = "ns.dependency", meta = {}, data = {component = "bee/bee", version = "3.0.0"}}}),
        })
        local prepared, problem = plan.prepare(captured, 1,
            request({action = "update", component = "bee/bee", version = "2.0.0"}), artifacts, baked_identity("1.0.0"))
        test.is_nil(problem); test.not_nil(prepared)
        if prepared then
            local settings = module_for(prepared.plan.modules, "bee/settings")
            test.not_nil(settings)
            if settings then test.eq(settings.version, "1.5.0"); test.eq(settings.change, "update") end
            test.is_nil(module_for(prepared.plan.modules, "bee/files"))
        end
    end)
    test.it("refuses self-update that resets an independently selected version", function()
        local selected_root = {id = "bee.deps:files", kind = "ns.dependency", meta = {type = "bee.component_selection"}, registry = {owner = "", root = true},
            data = {component = "bee/files", version = "1.5.0"}}
        local captured = state({selected_root, root("bee/bee", "1.0.0")},
            {{name = "bee/bee", version = "1.0.0"}, {name = "bee/files", version = "1.5.0"}})
        local prepared, problem = plan.prepare(captured, 2, request({action = "update", component = "bee/bee", version = "2.0.0"}),
            source({["bee/bee@2.0.0"] = package("bee/bee", "2.0.0", "a", {
                {id = "bee.deps:files", kind = "ns.dependency", meta = {type = "bee.component_selection"}, data = {component = "bee/files", version = "2.0.0"}},
            })}), baked_identity("1.0.0"))
        test.is_nil(prepared)
        test.eq(problem, "Bee self-update must leave component selection to host roots: bee.deps:files")
    end)

    test.it("refuses self-update that replaces the active Hub installer code", function()
        local captured = state({root("bee/bee", "1.0.0"),
            {id = "bee.deps:hub", kind = "ns.dependency", meta = {type = "bee.component_selection"}, registry = {owner = "bee/bee", root = true},
                data = {component = "bee/hub", version = "1.0.0"}},
            {id = "bee.hub.package:plan", kind = "library.lua", registry = {owner = "bee/hub"}, data = {source = "return {}"}},
        }, {{name = "bee/bee", version = "1.0.0"}, {name = "bee/hub", version = "1.0.0"}})
        local prepared, problem = plan.prepare(captured, 3, request({action = "update", component = "bee/bee", version = "2.0.0"}),
            source({["bee/bee@2.0.0"] = package("bee/bee", "2.0.0", "a", {
                {id = "bee.deps:hub", kind = "ns.dependency", meta = {type = "bee.component_selection"}, data = {component = "bee/hub", version = "2.0.0"}},
            }), ["bee/hub@2.0.0"] = package("bee/hub", "2.0.0", "b", {
                {id = "bee.hub.package:plan", kind = "library.lua", meta = {}, data = {source = "return {changed = true}"}},
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
                    data = {targets = {{entry = "bee.env.identity:binary_identity", path = ".data.setting"}}}},
            }, {requirements = {{id = "bee:setting", has_default = false, has_selected = false,
                targets = {{entry = "bee.env.identity:binary_identity", path = ".data.setting"}}}}, missing = {"bee:setting"}})}), baked_identity("1.0.0"))
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

end
return M
