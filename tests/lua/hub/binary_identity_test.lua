-- MIT.
local test = require("test")
local registry = require("registry")
local binary_identity = require("binary_identity")

local function define_tests()
    test.describe("Bee release binary identity", function()
        test.it("decodes the generated root pack entry", function()
            local entry, read_error = registry.get("bee.env:binary_identity")
            test.is_nil(read_error); test.not_nil(entry)
            local identity, problem = binary_identity.read_packages({{component = "bee/bee", entries = {entry}}})
            test.is_nil(problem); test.not_nil(identity)
            if identity then
                test.eq(identity.native, "github.com/wippyai/bee/native")
                test.is_true(identity.runtime_commit:sub(1, 1) == "v")
                test.is_true(#identity.native_components > 0)
            end
        end)
    end)
end

return test.run_cases(define_tests)
