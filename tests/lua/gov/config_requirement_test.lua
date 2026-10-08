-- MIT. Typed configuration evidence retains ownership and capability boundaries.
local test = require("test")
local requirement = require("requirement")
local preflight = require("preflight")
local function define_tests()
    test.describe("governed configuration", function()
        test.it("measures an integer default without interpreting it as a registry binding", function()
            local resolved, problem = requirement.resolve({id = "app:count", kind = "ns.requirement",
                meta = {schema = {type = "integer", minimum = 1}},
                data = {default = 4, targets = {{entry = "app:settings", path = ".limit"}}}}, "vendor/app",
                {["app:settings"] = {id = "app:settings", kind = "registry.entry", data = {limit = 0}}},
                {["app:settings"] = true}, nil)
            test.not_nil(resolved, problem)
            test.is_nil(assert(resolved).value)
            test.not_nil(assert(resolved).configuration_digest)
        end)
        test.it("refuses unowned configuration, capability fields and schema-invalid values", function()
            local entry = {id = "app:count", kind = "ns.requirement", meta = {schema = {type = "integer"}},
                data = {default = 4, targets = {{entry = "app:settings", path = ".limit"}}}}
            local final = {["app:settings"] = {id = "app:settings", kind = "registry.entry", data = {}}}
            test.is_nil(requirement.resolve(entry, "vendor/app", final, {}, nil))
            entry.data.targets[1].path = ".security.policies"
            test.is_nil(requirement.resolve(entry, "vendor/app", final, {["app:settings"] = true}, nil))
            entry.data.targets[1].path = ".limit"
            entry.meta.schema.type = "string"
            test.is_nil(requirement.resolve(entry, "vendor/app", final, {["app:settings"] = true}, nil))
        end)
    end)
end
return test.run_cases(define_tests)
