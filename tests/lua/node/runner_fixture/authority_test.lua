-- MIT. Reports the authority a test runs with: the application's own actor and
-- the exact scope its admission gives it.
local test = require("test")
local security = require("security")

local function define_tests()
    test.describe("authority", function()
        test.it("runs as an instance actor of the application", function()
            local actor = assert(security.actor())
            test.eq(actor:id():sub(1, #"bee.application:"), "bee.application:")
            local meta = actor:meta() :: {[string]: unknown}
            test.eq(meta.definition_id, "app.runner_fixture:app")
        end)
        test.it("holds what the admission grants", function()
            test.is_true(security.can("fixture.probe", "granted"))
        end)
        test.it("is denied what the application boundary leaves out", function()
            test.is_false(security.can("db.get", "bee:db"))
            test.is_false(security.can("registry.apply", "registry"))
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
