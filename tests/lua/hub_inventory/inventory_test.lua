-- MIT.
local test = require("test")
local inventory = require("inventory")
local function define_tests()
    test.describe("Hub installed inventory", function()
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
