-- MIT. The timeline application's declared policy must grant every function
-- target the application's own model calls. A read-only viewer that was
-- granted the listing but not the bounded change-wait renders the owner's
-- records and then reports the owner unavailable, because the missing grant
-- fails the wait on every pass. This test binds the two together.
local test = require("test")
local security = require("security")
local model = require("model")
local function define_tests()
    test.describe("Timeline policy coverage", function()
        test.it("grants the app's declared policy every target the model calls", function()
            local policy, policy_error = security.policy("bee.timeline:client_policy")
            if not policy then error("resolve bee.timeline:client_policy: " .. tostring(policy_error)) end
            local scope = security.new_scope({policy})
            local actor = security.actor()
            if not actor then error("test actor is unavailable") end
            local targets = {model.LIST, model.GET, model.SUBSCRIBE, model.PAGE, model.ACK_PAGE, model.RESUME, model.WATCH, model.RECAP}
            for _, target in ipairs(targets) do
                test.eq(scope:evaluate(actor, "funcs.call", target), "allow")
            end
        end)
    end)
end
return require("test").run_cases(define_tests)
