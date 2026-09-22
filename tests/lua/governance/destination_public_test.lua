-- MIT. The public facade reaches only destination-owned local state.
local funcs = require("funcs")
local test = require("test")

local function call(request: unknown): {[string]: unknown}
    local result, err = funcs.call("bee.governance.binding:destination_call", request)
    if type(result) ~= "table" then error(tostring(err or "destination call returned no result")) end
    return result :: {[string]: unknown}
end

local function define_tests()
    test.describe("destination delivery public facade", function()
        test.it("lists one authorized local workspace without selecting or activating", function()
            local result = call({operation = "list", workspace_id = "public-delivery-test"})
            test.is_true(result.ok == true)
            local value = result.value :: {[string]: unknown}
            test.eq(value.workspace_id, "public-delivery-test")
            test.eq(#(value.plans :: {unknown}), 0)
        end)

        test.it("fails closed when no host activation profile exists", function()
            local result = call({operation = "prepare", workspace_id = "public-delivery-test",
                source_node = "source-node", source_workspace = "vendor/app", version = "1.0.0",
                intent_id = "intent-1", receipt_key = "prepare-1"})
            test.is_false(result.ok == true)
            -- The facade names the owner's fault the way an application reads it.
            local fault = result.error :: {[string]: unknown}
            test.eq(fault.code, "BLOCKED")
            test.is_true((fault.message :: string):find("activation profile", 1, true) ~= nil)
        end)
    end)
end

return test.run_cases(define_tests)
