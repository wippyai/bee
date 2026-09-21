-- MIT. The default Hive service is host composition, not a reusable
-- supervisor capability and not an ordinary application grant.
local test = require("test")
local funcs = require("funcs")
local registry = require("registry")
local security = require("security")

local SERVICE = "bee.hive.host:supervisor_service"

local function ordinary_can(action: string, resource: string): boolean
    local policy, policy_error = security.policy("bee:base_app_policy")
    if not policy then error("load ordinary policy: " .. tostring(policy_error)) end
    local scope, scope_error = security.new_scope({policy})
    if not scope then error("create ordinary scope: " .. tostring(scope_error)) end
    local result, call_error = funcs.new():with_scope(scope):call("bee.host_policy_test:can_probe", {
        action = action, resource = resource,
    })
    if call_error then error("ordinary scope probe: " .. tostring(call_error)) end
    if type(result) ~= "boolean" then error("ordinary scope probe returned non-boolean") end
    return result
end

local function define_tests()
    test.describe("Hive host composition", function()
        test.it("declares the portable local supervisor service", function()
            local entry, err = registry.get(SERVICE)
            if not entry then error("missing default Hive service: " .. tostring(err)) end
            test.eq(entry.kind, "process.service")
            test.eq(entry.data.process, "bee.hive.supervisor:main")
            test.eq(entry.data.host, "bee.hive:supervisor_host")
            test.is_true(entry.data.lifecycle.auto_start)
            test.eq(entry.data.lifecycle.security.actor.id, "bee.hive.supervisor")
            local input = entry.data.input
            test.is_true(type(input) == "table" and #input == 1)
            test.is_true(type(input[1]) == "table")
            test.is_true(type(input[1].configured_nodes) == "table")
            test.eq(#input[1].configured_nodes, 0)
        end)

        test.it("does not give ordinary applications supervisor authority", function()
            test.is_false(ordinary_can("process.host", "bee.hive:supervisor_host"))
            test.is_false(ordinary_can("process.spawn", "bee.hive.supervisor:main"))
        end)
    end)
end

return test.run_cases(define_tests)
