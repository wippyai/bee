-- MIT. Scope management is selected only in a protected host binding.
local test = require("test")
local application = require("application")
local function define_tests()
    test.describe("Host scope-management binding", function()
        test.it("defaults to the ordinary boundary and requires explicit opt-in", function()
            local ordinary = application.binding({definition_id = "fixture:app", policies = {}})
            if not ordinary then error("ordinary binding") end
            test.is_false(ordinary.scope_management)
            local explicit = application.binding({definition_id = "fixture:app", policies = {}, scope_management = false})
            if not explicit then error("explicit ordinary binding") end
            test.is_false(explicit.scope_management)
            local trusted = application.binding({definition_id = "fixture:app", policies = {}, scope_management = true})
            if not trusted then error("trusted host binding") end
            test.is_true(trusted.scope_management)
        end)
        test.it("rejects nonboolean opt-in and unrecognized authority fields", function()
            for _, value in ipairs({"true", "false", 0, 1, {}} :: {unknown}) do
                test.is_nil(application.binding({definition_id = "fixture:app", policies = {}, scope_management = value}))
            end
            test.is_nil(application.binding({definition_id = "fixture:app", policies = {}, boundary_policy = "fixture:allow_all"}))
            test.is_nil(application.binding({definition_id = "fixture:app", policies = {}, scope = {}}))
            test.is_nil(application.binding({definition_id = "fixture:app", policies = {}, renderer_scope = true}))
        end)
    end)
end
return test.run_cases(define_tests)
