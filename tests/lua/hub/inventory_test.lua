-- MIT.
local test = require("test")
local inventory = require("inventory")
local function define_tests()
    test.describe("Hub installed inventory", function()
        test.it("projects planner protection through registry dependency ownership", function()
            local result = assert(inventory.decode({entries = {
                {id = "custom.boot:root", kind = "ns.dependency", registry = {owner = "", root = true},
                    data = {component = "custom/boot", version = "1.0.0"}},
                {id = "custom.boot:runtime", kind = "ns.dependency", registry = {owner = "custom/boot"},
                    data = {component = "custom/runtime", version = "1.0.0"}},
                {id = "custom:independent", kind = "ns.dependency", meta = {type = "bee.hub_dependency"}, registry = {owner = "", root = true},
                    data = {component = "custom/app", version = "1.0.0"}},
            }}, 1))
            test.is_nil(result.modules[1].update_reason)
            test.eq(result.modules[3].update_reason,
                "protected boot/installer component cannot be updated independently: custom/runtime; required by custom.boot:runtime")
        end)
        test.it("derives independent selection from the host dependency without a second record", function()
            local result = assert(inventory.decode({entries = {
                {id = "bee.deps:files", kind = "ns.dependency", meta = {type = "bee.component_selection", independent = true}, registry = {owner = "bee/bee", root = true},
                    data = {component = "bee/files", version = "1.0.0", parameters = {{name = "folder", value = "selected"}}}},
                {id = "bee.deps:hub", kind = "ns.dependency", meta = {type = "bee.component_selection"}, registry = {owner = "", root = true},
                    data = {component = "bee/hub", version = "1.0.0"}},
            }}, 4))
            test.eq(#result.roots, 2)
            test.eq(result.roots[1].managed, true)
            test.eq(result.roots[1].parameters[1].value, "selected")
            test.eq(result.roots[2].managed, false)
            test.eq(#result.modules[1].used_by, 0)
        end)
        test.it("does not grant independent management to another package's selection", function()
            local result = assert(inventory.decode({entries = {
                {id = "bee.deps:files", kind = "ns.dependency", meta = {type = "bee.component_selection", independent = true}, registry = {owner = "acme/app", root = true},
                    data = {component = "bee/files", version = "1.0.0"}},
            }}, 1))
            test.eq(result.roots[1].managed, false)
            test.is_false(inventory.host_component(result.roots[1]))
            test.is_nil(result.conversion)
            test.eq(result.modules[2].used_by[1], "acme/app")
        end)
        test.it("discovers host selection by metadata regardless of namespace and component spelling", function()
            local result = assert(inventory.decode({entries = {
                {id = "custom.selection:editor", kind = "ns.dependency", meta = {type = "bee.component_selection", independent = true},
                    registry = {owner = "bee/bee", root = true}, data = {component = "acme/editor", version = "1.0.0"}},
            }}, 1))
            test.is_true(result.roots[1].managed)
            test.is_true(inventory.host_component(result.roots[1]))
            test.eq(assert(result.conversion).roots[1].id, "custom.selection:editor")
            test.eq(#result.modules[1].used_by, 0)
        end)
        test.it("does not treat an untagged host dependency as an independent selection", function()
            local result = assert(inventory.decode({entries = {
                {id = "bee.deps:files", kind = "ns.dependency", meta = {independent = true}, registry = {owner = "bee/bee", root = true},
                    data = {component = "bee/files", version = "1.0.0"}},
            }}, 1))
            test.is_false(result.roots[1].managed)
            test.is_false(inventory.host_component(result.roots[1]))
            test.is_nil(result.conversion)
            test.eq(result.modules[2].used_by[1], "bee/bee")
        end)
        test.it("leaves third-party declarations in the host namespace outside Bee root conversion", function()
            local result = assert(inventory.decode({entries = {
                {id = "bee.deps:external", kind = "ns.dependency", registry = {owner = "bee/bee", root = true},
                    data = {component = "acme/app", version = "^1.0.0", parameters = {{name = "port", value = 8080}}}},
            }}, 1))
            test.is_nil(result.conversion)
            test.eq(result.roots[1].version, "^1.0.0")
            test.eq(result.roots[1].parameters[1].value, 8080)
            test.eq(result.modules[1].used_by[1], "bee/bee")
        end)
        test.it("uses registry ownership and one resolution for roots and shared dependencies", function()
            local result, problem = inventory.decode({resolution = {modules = {
                {name = "acme/app", version = "1.2.0", source = "hub"},
                {name = "acme/shared", version = "2.1.0", source = "hub"},
            }}, entries = {
                {id = "app.deps:one", kind = "ns.dependency", registry = {owner = "", root = true},
                    data = {component = "acme/app", version = "^1.0.0"}},
                {id = "app.deps:two", kind = "ns.dependency", registry = {owner = "", root = true},
                    data = {component = "acme/app", version = "1.2.0", parameters = {{name = "acme.app:port", value = 8080}}}},
                {id = "acme.app:shared", kind = "ns.dependency", registry = {owner = "acme/app", root = false},
                    data = {component = "acme/shared", version = "^2.0.0"}},
                {id = "acme.shared:lib", kind = "library.lua", registry = {owner = "acme/shared", root = false}},
                {id = "local:fake", kind = "registry.entry", registry = {owner = "", root = false},
                    meta = {owner = "acme/shared", module = "acme/shared"}},
            }}, 7)
            test.is_nil(problem)
            test.not_nil(result)
            if not result then return end
            test.eq(result.version, 7)
            test.eq(#result.modules, 2)
            test.eq(result.modules[1].component, "acme/app")
            test.eq(result.modules[1].version, "1.2.0")
            test.eq(#result.modules[1].roots, 2)
            test.eq(result.modules[1].direct, true)
            test.eq(result.modules[2].direct, false)
            test.eq(result.modules[2].used_by[1], "acme/app")
            test.eq(result.modules[2].entries, 1)
            test.eq(result.roots[2].parameters[1].value, 8080)
        end)
        test.it("uses the standalone lock identity with live selections and keeps pins separate", function()
            local state = {entries = {}, resolution = {modules = {{name = "bee/bee", version = "1.1.0", digest = "sha256:" .. string.rep("a", 64)}},
                lock = {root_module = "bee/bee", modules = {{name = "bee/bee", version = "1.0.0"}}}}}
            local result = assert(inventory.decode(state, 1))
            test.eq(#result.roots, 0)
            test.eq(result.deployment, "bee/bee")
            test.eq(#result.modules[1].roots, 0)
            test.eq(result.modules[1].locked_version, "1.0.0")
            test.eq(result.modules[1].digest, string.rep("a", 64))
            test.is_true(result.modules[1].direct)
            state.resolution.lock.root_module = "bad"
            test.is_nil(inventory.decode(state, 1))
        end)
        test.it("keeps the approved root and parameters after a standalone update", function()
            local result = assert(inventory.decode({entries = {{id = "bee:deployment", kind = "ns.dependency",
                registry = {owner = "", root = true}, data = {component = "bee/bee", version = "1.1.0",
                    parameters = {{name = "setting", value = "kept"}}}}},
                resolution = {modules = {{name = "bee/bee", version = "1.1.0"}},
                    lock = {root_module = "bee/bee", modules = {{name = "bee/bee", version = "1.0.0"}}}}}, 2))
            test.eq(#result.roots, 1)
            test.eq(result.roots[1].parameters[1].value, "kept")
        end)
        test.it("reads a host root whose parameters address requirements by bare name", function()
            local result, problem = inventory.decode({entries = {
                {id = "host:dependency_store", kind = "ns.dependency", registry = {owner = "", root = true},
                    data = {component = "acme/store", version = "0.1.0", parameters = {{name = "target_db", value = "host:db"}}}},
            }}, 3)
            test.is_nil(problem)
            test.not_nil(result)
            if not result then return end
            test.eq(result.roots[1].parameters[1].name, "target_db")
            test.eq(result.roots[1].parameters[1].value, "host:db")
        end)
        test.it("does not infer a root or owner from authored metadata", function()
            local result = inventory.decode({entries = {
                {id = "app.deps:fake", kind = "ns.dependency", registry = {owner = "", root = false},
                    meta = {root = true, module = "acme/app"}, data = {component = "acme/app", version = "1.0.0"}},
            }}, 0)
            test.not_nil(result)
            if not result then return end
            test.eq(#result.roots, 0)
            test.eq(result.modules[1].direct, false)
            test.eq(result.modules[1].entries, 0)
        end)
        test.it("refuses missing ownership, duplicate entries, malformed lists and modules", function()
            test.is_nil(inventory.decode({entries = {{id = "local:missing", kind = "registry.entry"}}}, 0))
            local entry = {id = "local:one", kind = "registry.entry", registry = {owner = "", root = false}}
            test.is_nil(inventory.decode({entries = {entry, entry}}, 0))
            test.is_nil(inventory.decode({entries = {[2] = entry}}, 0))
            test.is_nil(inventory.decode({entries = {}, resolution = {modules = {{name = "../app", version = "1.0.0"}}}}, 0))
            test.is_nil(inventory.decode({entries = {}}, -1))
        end)
    end)
end
return test.run_cases(define_tests)
