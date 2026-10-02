-- MIT. Public owner operations reject malformed input before touching state.
local test = require("test")
local funcs = require("funcs")
local bounds = require("bounds")

local function define_tests()
    test.describe("Sessions owner boundary", function()
        test.it("rejects non-object requests through every registered method", function()
            for _, method in ipairs({"open", "run", "send", "await", "join", "get", "list", "history",
                "cancel", "close", "catalog", "attach", "detach", "hook_boundary", "attention_count"}) do
                local raw, problem = funcs.call("bee.sessions.binding:" .. method, "invalid")
                test.is_nil(problem, method)
                local reply = assert(bounds.object(raw))
                test.eq(reply.ok, false, method)
                test.eq(assert(bounds.object(reply.error)).code, "INVALID", method)
            end
        end)
    end)
end

return test.run_cases(define_tests)
