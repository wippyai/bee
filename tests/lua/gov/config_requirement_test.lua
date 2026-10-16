-- MIT. Typed configuration evidence retains ownership and capability boundaries.
local test = require("test")
local requirement = require("requirement")
local function define_tests()
    test.describe("governed configuration", function()
        test.it("measures exact security group members and excludes operation vocabulary", function()
            local entry = {id = "host:service", kind = "process.service", meta = {operation_ref = "domain:operation"},
                data = {process = "other:process", lifecycle = {security = {groups = {"host:workers"}}}}}
            local captured: {{[string]: unknown}} = {
                {id = "vendor:policy", kind = "security.policy", data = {groups = {"host:workers"}}},
                {id = "vendor:unrelated", kind = "security.policy", data = {groups = {"host:workers.extra"}}},
            }
            local refs = assert(requirement.references(entry, captured))
            test.eq(#refs, 2)
            test.eq(refs[1], "other:process")
            test.eq(refs[2], "vendor:policy")
            test.is_nil(requirement.references(entry, {}))
        end)
        test.it("measures an integer default without interpreting it as a registry binding", function()
            local resolved, problem = requirement.resolve({id = "app:count", kind = "ns.requirement",
                meta = {schema = {type = "integer", minimum = 1}},
                data = {default = 4, targets = {{entry = "app:settings", path = ".limit"}}}}, "vendor/app",
                {["app:settings"] = {id = "app:settings", kind = "registry.entry", data = {limit = 0}}},
                {["app:settings"] = true})
            test.not_nil(resolved, problem)
            test.is_nil(assert(resolved).value)
            test.not_nil(assert(resolved).configuration_digest)
        end)
        test.it("refuses unowned configuration, capability fields and schema-invalid values", function()
            local entry = {id = "app:count", kind = "ns.requirement", meta = {schema = {type = "integer"}},
                data = {default = 4, targets = {{entry = "app:settings", path = ".limit"}}}}
            local final = {["app:settings"] = {id = "app:settings", kind = "registry.entry", data = {}}}
            test.is_nil(requirement.resolve(entry, "vendor/app", final, {}))
            entry.data.targets[1].path = ".security.policies"
            test.is_nil(requirement.resolve(entry, "vendor/app", final, {["app:settings"] = true}))
            entry.data.targets[1].path = ".limit"
            entry.meta.schema.type = "string"
            test.is_nil(requirement.resolve(entry, "vendor/app", final, {["app:settings"] = true}))
        end)
    end)
end
return test.run_cases(define_tests)
