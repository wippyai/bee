-- MIT. The owner must invoke each scoped task under its declared authority.
local test = require("test")
local registry = require("registry")
local security = require("security")
local funcs = require("funcs")
local bounds = require("bounds")

local function define_tests()
    test.describe("Gateway effect owner authority", function()
        test.it("discovers consumers, reads the backlog and dispatches both empty drains", function()
            local entry = assert(registry.get("bee.gateway.service:external_service"))
            local lifecycle = assert(bounds.object(assert(bounds.object(entry.data)).lifecycle))
            local declared = assert(bounds.object(lifecycle.security))
            local actor = assert(bounds.object(declared.actor))
            local policies: {security.Policy} = {}
            for _, id in ipairs(assert(bounds.ids(declared.policies))) do
                policies[#policies + 1] = assert(security.policy(id))
            end
            local reply, problem = funcs.new():with_actor(assert(security.new_actor(assert(bounds.id(actor.id)))))
                :with_scope(assert(security.new_scope(policies))):call("bee.gateway:effects_scope_probe")
            test.is_nil(problem, tostring(problem))
            local result = assert(bounds.object(reply))
            test.eq(result.pending, false)
            test.eq(result.installation, true)
            test.eq(result.publication, true)
        end)
    end)
end
return test.run_cases(define_tests)
