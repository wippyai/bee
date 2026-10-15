-- MIT. Focused overlay resolver test cases.
local test = require("test")
local function define_tests()
    test.describe("Workspace driver admission", function()
        require("overlay_driver_cases").define()
    end)

    test.describe("private overlay artifact resolver", function()
        require("overlay_artifact_cases").define()
    end)
end

return test.run_cases(define_tests)
