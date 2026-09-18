-- MIT. Saved effort is a bounded native Codex option, never prompt content.
local test = require("test")
local launch = require("launch")
local function define_tests()
    test.describe("Codex selected effort", function()
        test.it("qualifies fresh and resumed window launches before the prompt delimiter", function()
            for _, resume in ipairs({"", "conversation-id"}) do
                local request, err = launch.decode({profile_id = "window", brief = "--literal task",
                    effort = "high", resume_ref = resume ~= "" and resume or nil, gateway_hooks = {"SessionStart"}})
                if not request then error(tostring(err)) end
                local result = launch.specification(request)
                test.eq(result.argv[1], "--config")
                test.eq(result.argv[2], 'model_reasoning_effort="high"')
                test.eq(result.argv[#result.argv], "--literal task")
                test.eq(result.argv[#result.argv - 1], "--")
            end
        end)
        test.it("rejects invalid effort and leaves unselected launches without an override", function()
            test.is_nil(launch.decode({profile_id = "window", brief = "", effort = 'high" injected=true'}))
            test.is_nil(launch.decode({profile_id = "window", brief = "", effort = false}))
            local request, err = launch.decode({profile_id = "window", brief = ""})
            if not request then error(tostring(err)) end
            local result = launch.specification(request)
            test.eq(result.argv[1], "--sandbox")
        end)
    end)
end
return test.run_cases(define_tests)
