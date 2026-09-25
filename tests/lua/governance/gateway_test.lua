-- MIT. The capability gateway serves only an authenticated application
-- principal with its own live grant; any other caller is refused before a
-- binding is opened or a request is sent.
local funcs = require("funcs")
local security = require("security")
local test = require("test")

local function call(target: string, request: unknown, actor: unknown?): {[string]: unknown}
    local executor = funcs.new()
    if actor then executor = executor:with_actor(actor) end
    local result, err = executor:call(target, request)
    if type(result) ~= "table" then error(tostring(err or "gateway returned no result")) end
    return result :: {[string]: unknown}
end

local function code(result: {[string]: unknown}): unknown
    local fault = result.error :: {[string]: unknown}
    return fault.code
end

local function define_tests()
    test.describe("capability gateway", function()
        test.it("refuses a caller that is not an application principal", function()
            local contract = call("bee.gov.binding:contract_call", {binding = "app.peer:api", method = "get"})
            test.is_false(contract.ok == true)
            test.eq(code(contract), "DENIED")
            local http = call("bee.gov.binding:http_request", {method = "GET", url = "https://api.example.com/v1"})
            test.is_false(http.ok == true)
            test.eq(code(http), "DENIED")
        end)
        test.it("refuses an application principal without an installed grant", function()
            local workspace = string.rep("c", 32)
            local actor = security.new_actor("bee.application:" .. workspace .. ":instance-1",
                {workspace_id = workspace, definition_id = "app.absent:app", definition_revision = "1",
                    execution_generation = 1})
            local contract = call("bee.gov.binding:contract_call", {binding = "app.peer:api", method = "get"}, actor)
            test.eq(code(contract), "DENIED")
            local http = call("bee.gov.binding:http_request", {method = "GET", url = "https://api.example.com/v1"},
                actor)
            test.eq(code(http), "DENIED")
        end)
        test.it("refuses malformed requests", function()
            test.eq(code(call("bee.gov.binding:contract_call", {binding = "app.peer:api", method = "get",
                extra = true})), "INVALID")
            test.eq(code(call("bee.gov.binding:http_request", {method = "GET", url = "https://api.example.com/v1",
                timeout = 600})), "INVALID")
        end)
    end)
end

return test.run_cases(define_tests)
