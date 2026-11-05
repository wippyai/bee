-- SPDX-License-Identifier: MIT
-- Agent windows subscribe to their binding's hook signal under the Agents presentation authority.
local test = require("test")
local registry = require("registry")
local security = require("security")
local funcs = require("funcs")
local bounds = require("bounds")
local function scope(id: string): security.Scope
    local entry = assert(registry.get(id))
    local data = assert(bounds.object(entry.data))
    local declared = assert(bounds.object(data.security))
    local policies: {security.Policy} = {}
    for _, policy in ipairs(assert(bounds.ids(declared.policies))) do policies[#policies + 1] = assert(security.policy(policy)) end
    return security.new_scope(policies)
end
local function define_tests()
    test.describe("Agent window hook signal authority", function()
        test.it("subscribes to the binding's hook signal under every entry that runs a window", function()
            for _, id in ipairs({"bee.harness.service:presentation_owner", "bee.harness.app:app"}) do
                local raw, problem = funcs.new():with_actor(security.new_actor("bee.test.hook_signal_scope")):with_scope(scope(id))
                    :call("bee.tests.harness:hook_signal_probe", {})
                test.is_nil(problem, id .. ": " .. tostring(problem))
                local result = assert(bounds.object(raw))
                test.is_nil(result.error, id .. ": " .. tostring(result.error))
                test.eq(result.subscribed, true, id)
            end
        end)
    end)
end
return test.run_cases(define_tests)
