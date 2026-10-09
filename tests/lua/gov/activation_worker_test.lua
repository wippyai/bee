-- MIT. The activation worker runs under the policies its service declares;
-- they admit what it does at start and on each wake.
local test = require("test")
local registry = require("registry")
local security = require("security")

local function service_scope(): security.Scope
    local entry = assert(registry.get("bee.gov.service:activation_service"))
    local lifecycle = assert((entry.data :: {[string]: unknown}).lifecycle) :: {[string]: unknown}
    local declared = assert((lifecycle.security :: {[string]: unknown}).policies) :: {string}
    local policies: {security.Policy} = {}
    for index, id in ipairs(declared) do policies[index] = assert(security.policy(id)) end
    return security.new_scope(policies)
end

local function define_tests()
    test.describe("Activation worker", function()
        test.it("may register the name approvals wakes it by and read approved and ended activations", function()
            local scope = service_scope()
            local actor = security.new_actor("bee.gov.activation")
            test.eq(scope:evaluate(actor, "process.registry.register", "bee.gov.activation_worker"), "allow")
            test.eq(scope:evaluate(actor, "bee.approvals.own", "gov.activation"), "allow")
            test.eq(scope:evaluate(actor, "bee.approvals.own", "gov.activation"), "allow")
            test.eq(scope:evaluate(actor, "events.send", "bee.attention"), "allow")
        end)
    end)
end

return test.run_cases(define_tests)
