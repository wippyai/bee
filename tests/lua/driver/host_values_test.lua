-- MIT. Driver overrides read only the host's nonsecret facts: a provider
-- variable set in the shell that started Bee (a config directory or an API
-- key) never reaches an agent's launch through the driver's variables.
local test = require("test")
local env = require("env")

local function define_tests()
    test.describe("driver host values", function()
        test.it("leaves provider variables of the starting shell out of the driver overrides", function()
            for _, id in ipairs({"bee.driver.claude.env:config_home", "bee.driver.claude.env:api_key",
                "bee.driver.codex.env:config_home"}) do
                local value = env.get(id)
                test.eq(value or "", "", id .. " reads the starting shell")
            end
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
