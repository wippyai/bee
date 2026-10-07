-- MIT. Application test association across namespaces.
local test = require("test")
local security = require("security")
local function define_tests()
    test.describe("package application", function()
        test.it("runs as its associated application", function()
            local actor = assert(security.actor())
            local meta = actor:meta() :: {[string]: unknown}
            test.eq(meta.definition_id, "bee.tests.node.hub_tests_fixture:application")
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
