-- MIT.
local test = require("test")
local registry = require("registry")
local bounds = require("bounds")
local definitions = require("definitions")
local policy = require("policy")
local function define_tests()
    test.describe("Normal provider authoring policies", function()
        test.it("admits the guide, offline docs and delivery on normal provider session routes", function()
            local authoring = {"capabilities", "overlay", "docs", "components", "delivery"}
            for _, provider in ipairs({"codex", "claude", "agy", "grok", "muse", "opencode"}) do
                local ref = "bee.driver." .. provider .. ":default_window"
                local launch, definition_error = definitions.decode(ref, assert(registry.get(ref)))
                if not launch then error(tostring(definition_error)) end
                test.not_nil(launch.session_profile_id)
                local decoded, policy_error = policy.decode(launch.policy_ref, assert(registry.get(launch.policy_ref)),
                    function(_ref: string): (string?, string?) return "/usr/bin/agent-fixture", nil end)
                if not decoded then error(tostring(policy_error)) end
                for _, tool in ipairs(authoring) do
                    test.is_true(bounds.member(tool, decoded.gateway_tools) ~= nil, ref .. " omits " .. tool)
                end
                test.is_nil(bounds.member("publish", decoded.gateway_tools))
                test.is_nil(bounds.member("workspace", decoded.gateway_tools))
            end
        end)
    end)
end
return test.run_cases(define_tests)
