-- MIT.
local test = require("test")
local registry = require("registry")
local bounds = require("bounds")
local definitions = require("definitions")
local policy = require("policy")
local function define_tests()
    test.describe("Normal provider authoring policies", function()
        test.it("admits the guide, offline docs and delivery on normal provider window routes and offers application tools and sharing as access the person approves", function()
            local authoring = {"capabilities", "overlay", "docs", "components", "delivery"}
            for _, provider in ipairs({"codex", "claude", "agy", "grok", "muse", "opencode"}) do
                local ref = "bee.driver." .. provider .. ".profiles:default_window"
                local launch, definition_error = definitions.decode(ref, assert(registry.get(ref)))
                if not launch then error(tostring(definition_error)) end
                test.eq(launch.default_mode, "window")
                local decoded, policy_error = policy.decode(launch.policy_ref, assert(registry.get(launch.policy_ref)),
                    function(_ref: string): (string?, string?) return "/usr/bin/agent-fixture", nil end)
                if not decoded then error(tostring(policy_error)) end
                for _, tool in ipairs(authoring) do
                    test.is_true(bounds.member(tool, decoded.gateway_tools) ~= nil, ref .. " omits " .. tool)
                end
                -- Application tools and sharing reach the agent only through the
                -- person: the stock surface offers them as access to approve.
                local surface = assert(decoded.gateway_surface, ref .. " offers no access")
                for _, tool in ipairs({"app_tools", "publish", "components", "install_request", "uninstall_request", "install_status"}) do
                    test.is_true(bounds.member(tool, decoded.gateway_tools) ~= nil, ref .. " omits " .. tool)
                    test.is_nil(bounds.member(tool, surface.base_tools :: {string}), ref .. " grants " .. tool .. " without the person")
                end
                local access = assert(surface.access) :: {policy: string, traits: {string}}
                test.eq(access.policy, "agent-access")
                test.eq(table.concat(access.traits, ","), "bee.app:share,bee.app:tools,bee.hub:library")
                test.is_nil(bounds.member("workspace", decoded.gateway_tools))
            end
        end)
    end)
end
return test.run_cases(define_tests)
