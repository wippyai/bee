-- MIT. The public overlay facade projects storage vocabulary at its boundary.
local funcs = require("funcs")
local test = require("test")

local function call(request: unknown): {[string]: unknown}
    local result, err = funcs.call("bee.governance.binding:overlay_call", request)
    if type(result) ~= "table" then error(tostring(err or "overlay call returned no result")) end
    return result :: {[string]: unknown}
end

local function define_tests()
    test.describe("Governance overlay facade vocabulary", function()
        test.it("projects lower-layer workspace failures at the public boundary", function()
            local result = call({operation = "list", overlay_id = "method-vocabulary-missing"})
            test.is_false(result.ok == true)
            test.eq(result.code, "NOT_FOUND")
            test.eq(result.message, "overlay does not exist")
        end)

        test.it("uses overlay terminology for invalid public requests", function()
            local result = call({operation = "publish", overlay_id = "method-vocabulary-invalid"})
            test.is_false(result.ok == true)
            test.eq(result.code, "INVALID")
            test.eq(result.message, "unknown overlay operation")
        end)
    end)
end

return test.run_cases(define_tests)
