-- MIT. The Hub publisher host comes only from the root component dependency.
local test = require("test")
local host_resources = require("host_resources")

local function define_tests()
    test.describe("Hub process host requirement", function()
        test.it("uses the root-injected process host", function()
            local host, problem = host_resources.process_host()
            test.is_nil(problem)
            test.eq(host, "bee:workers")
        end)
    end)
end

return test.run_cases(define_tests)
