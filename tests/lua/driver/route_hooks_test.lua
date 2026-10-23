-- MIT. Bee's shipped launch routes request exactly the gateway hooks their
-- driver bindings declare and deliver.
local test = require("test")
local resolver = require("resolver")
local registry = require("registry")
local bounds = require("bounds")

local function define_tests()
    test.describe("Bee launch route hooks", function()
        test.it("declares exactly the hooks each shipped route requests and delivers", function()
            local pinned = assert(registry.snapshot())
            local routes = assert(registry.find({["meta.type"] = "bee.launch_definition"}))
            local audited = {agy = true, grok = true, muse = true, codex = true}
            local checked = 0
            for _, route in ipairs(routes) do
                local data = assert(bounds.object(route.data))
                local binding = type(data.binding_ref) == "string" and pinned:get(data.binding_ref) or nil
                local meta = binding and bounds.object(binding.meta)
                local provider = meta and bounds.id(meta.driver_id)
                if provider and audited[provider] then
                    local selected = assert(resolver.profile(pinned, tostring(data.binding_ref), tostring(data.profile_id)))
                    local policy = assert(pinned:get(tostring(data.policy_ref)))
                    local requested = assert(bounds.ids(assert(bounds.object(policy.data)).gateway_hooks or {}, true))
                    local delivered = resolver.select_hooks(selected, requested)
                    test.eq(#delivered, #requested, route.id)
                    local declared = selected.hooks and selected.hooks.events or {}
                    test.eq(#declared, #delivered, route.id)
                    for _, event in ipairs(declared) do test.not_nil(bounds.member(event, delivered), route.id .. ": " .. event) end
                    checked = checked + 1
                end
            end
            test.is_true(checked >= 9)
        end)
        test.it("delivers acceptance and settlement hooks on Agy Grok and Muse windows", function()
            local pinned = assert(registry.snapshot())
            for _, provider in ipairs({"agy", "grok", "muse"}) do
                local binding = "bee.drivers." .. provider .. ".binding:binding"
                local selected = assert(resolver.profile(pinned, binding, "window"))
                local policy = assert(pinned:get("bee.driver." .. provider .. ".security:launch_policy_" .. provider .. "_window"))
                local requested = assert(bounds.ids(assert(bounds.object(policy.data)).gateway_hooks, true))
                local delivered = resolver.select_hooks(selected, requested)
                test.not_nil(bounds.member("UserPromptSubmit", delivered))
                test.not_nil(bounds.member("Stop", delivered))
            end
        end)
    end)
end
return test.run_cases(define_tests)
