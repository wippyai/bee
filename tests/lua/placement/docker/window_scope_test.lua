-- SPDX-License-Identifier: MIT
-- Agent windows open their Docker sessions under the Agents presentation authority.
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
    test.describe("Docker agent window authority", function()
        test.it("selects the profile home executor under every presentation entry that opens windows", function()
            for _, id in ipairs({"bee.harness.service:presentation_owner", "bee.harness.service:open", "bee.harness.service:restore"}) do
                local raw, problem = funcs.new():with_actor(security.new_actor("bee.test.window_scope")):with_scope(scope(id))
                    :call("bee.tests.placement.docker:window_scope_probe", {})
                test.is_nil(problem, id .. ": " .. tostring(problem))
                local result = assert(bounds.object(raw))
                test.is_nil(result.error, id .. ": " .. tostring(result.error))
                test.not_nil(result.ref, id)
            end
            local overlay = assert(registry.overlay("bee.placement.docker:homes"))
            local changes = overlay:changes()
            for _, entry in ipairs(assert(overlay:entries())) do
                if entry.kind == "exec.docker" and tostring(entry.id):find("bee.placement.docker:home-", 1, true) == 1 then changes:delete(entry.id) end
            end
            assert(changes:apply())
        end)
    end)
end
return test.run_cases(define_tests)
