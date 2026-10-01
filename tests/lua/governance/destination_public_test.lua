-- MIT. The public facade reaches only destination-owned local state.
local funcs = require("funcs")
local test = require("test")
local principals = require("principals")
local bounds = require("bounds")

local function call(request: unknown): {[string]: unknown}
    local result, err = funcs.call("bee.gov.binding:destination_call", request)
    if type(result) ~= "table" then error(tostring(err or "destination call returned no result")) end
    return assert(bounds.object(result))
end

local function define_tests()
    test.describe("destination delivery public facade", function()
        test.it("lists one authorized local workspace without selecting or activating", function()
            local result = call({operation = "list", workspace_id = "public-delivery-test"})
            test.is_true(result.ok == true)
            local value = assert(bounds.object(result.value))
            test.eq(value.workspace_id, "public-delivery-test")
            test.eq(#(principals.items(value.plans)), 0)
        end)

        test.it("fails closed when no host activation profile exists", function()
            local result = call({operation = "prepare", workspace_id = "public-delivery-test",
                source_node = "source-node", source_workspace = "vendor/app", version = "1.0.0",
                intent_id = "intent-1", receipt_key = "prepare-1"})
            test.is_false(result.ok == true)
            -- The facade names the owner's fault the way an application reads it.
            local fault = assert(bounds.object(result.error))
            test.eq(fault.code, "BLOCKED")
            test.is_true((fault.message):find("activation profile", 1, true) ~= nil)
        end)
    end)
end

return test.run_cases(define_tests)
