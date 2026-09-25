-- MIT. The gateway's remote session resolver: with no host-selected transport
-- linked it resolves nothing, so a node-qualified address is answered as not
-- found rather than guessed. Resolution is discovery: the destination still
-- re-checks every grant when a send arrives.
local test = require("test")
local remote = require("remote")

local function define_tests()
    test.describe("Gateway remote session resolver", function()
        test.it("resolves nothing when no transport is linked", function()
            local resolved, refusal = remote.resolve({node_id = "node-b", action_id = "action-b"})
            test.is_nil(resolved)
            test.not_nil(refusal)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
