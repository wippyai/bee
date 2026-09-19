-- MIT. Saved profile values stay within the host-selected launch policy.
local test = require("test")
local preferences = require("preferences")

local function policy(): {[string]: unknown}
    return {
        prepare_options = {model = "base", effort = "low"},
        instructions = "Host guidance",
        gateway_tools = {"thread_wait", "thread_read"},
        gateway_hooks = {"SessionStart", "Stop"},
        profile_options = {model = {"small", "large"}, effort = {"low", "high"}, enabled = {false, true}},
        profile_instructions = true,
        retained = {owner = "host"},
    }
end

local function apply(raw: {[string]: unknown}, host: {[string]: unknown}?): {[string]: unknown}
    local value, err = preferences.apply(host or policy(), raw)
    if not value then error(tostring(err)) end
    return value
end

local function define_tests()
    test.describe("Saved driver preferences", function()
        test.it("decodes only bounded preference fields", function()
            local value, err = preferences.decode({options = {model = "small"}, mcp_tools = {"thread_read"}, instructions = "Use tests."})
            if not value then error(tostring(err)) end
            test.eq(value.options.model, "small")
            test.eq(value.mcp_tools[1], "thread_read")
            test.eq(value.instructions, "Use tests.")
            local false_value = preferences.decode({options = {enabled = false}})
            if not false_value then error("false scalar was rejected") end
            test.is_false(false_value.options.enabled)
            for _, field in ipairs({"profile_id", "brief", "resume_ref", "permission_exchange", "gateway_tools", "gateway_hooks", "unknown"}) do
                local raw: {[string]: unknown} = {}
                raw[field] = true
                test.is_nil(preferences.decode(raw))
            end
            test.is_nil(preferences.decode({options = {profile_id = "host"}}))
            test.is_nil(preferences.decode({options = {model = {nested = true}}}))
            test.is_nil(preferences.decode({options = {model = math.huge}}))
        end)

        test.it("rejects unknown, reserved, and unallowed option values", function()
            local false_value = apply({options = {enabled = false}, instructions = ""})
            test.is_false(false_value.prepare_options.enabled)
            test.is_nil(preferences.apply(policy(), {options = {unknown = "x"}}))
            test.is_nil(preferences.apply(policy(), {options = {profile_id = "x"}}))
            test.is_nil(preferences.apply(policy(), {options = {model = "unsafe"}}))
            test.is_nil(preferences.apply(policy(), {options = {gateway_tools = "thread_read"}}))
            test.is_nil(preferences.apply(policy(), {mcp_tools = {"outside"}}))
        end)

        test.it("carries a named Codex profile only when the policy enables it", function()
            local host = policy()
            test.is_nil(preferences.apply(host, {config_profile = "ds-flash"}))
            host.profile_config_profile = true
            local applied = apply({config_profile = "ds-flash"}, host)
            test.eq(applied.prepare_options.config_profile, "ds-flash")
            test.is_nil(preferences.decode({config_profile = "a/b"}))
            test.is_nil(preferences.decode({config_profile = ""}))
            test.is_nil(preferences.decode({config_profile = string.rep("x", 65)}))
            test.is_nil(preferences.decode({config_profile = "a.b"}))
            host.profile_config_profile = "yes"
            test.is_nil(preferences.apply(host, {config_profile = "ds-flash"}))
        end)

        test.it("rejects malformed host option allowlists before applying a profile", function()
            for _, malformed in ipairs({
                {model = {}},
                {model = {[1] = "small", [3] = "large"}},
                {model = {string.rep("x", 513)}},
                {model = {{nested = true}}},
                {profile_id = {"unsafe"}},
            }) do
                local host = policy()
                host.profile_options = malformed
                test.is_nil(preferences.apply(host, {}))
            end
        end)

        test.it("sorts a permitted MCP subset and preserves hooks", function()
            local host = policy()
            local hooks = host.gateway_hooks
            local value = apply({mcp_tools = {"thread_wait", "thread_read"}, instructions = ""}, host)
            test.eq(value.gateway_tools[1], "thread_read")
            test.eq(value.gateway_tools[2], "thread_wait")
            test.eq(value.gateway_hooks, hooks)
            test.eq(#value.gateway_tools, 2)
            local empty = apply({mcp_tools = {}, instructions = ""}, host)
            test.eq(#empty.gateway_tools, 0)
            test.eq(empty.gateway_hooks, hooks)
        end)

        test.it("appends enabled profile guidance within the shared bound", function()
            local value = apply({instructions = "Saved"})
            test.eq(value.instructions, "Host guidance\n\nSaved")
            local disabled = policy()
            disabled.profile_instructions = false
            test.is_nil(preferences.apply(disabled, {instructions = "Saved"}))
            local retained = apply({instructions = ""}, disabled)
            test.eq(retained.instructions, "Host guidance")

            local too_long = policy()
            too_long.instructions = string.rep("h", 4090)
            test.is_nil(preferences.apply(too_long, {instructions = "saved"}))
            local exact = policy()
            exact.instructions = string.rep("h", 4090)
            local exact_value = apply({instructions = ""}, exact)
            test.eq(#exact_value.instructions, 4090)
            local no_guidance = policy()
            no_guidance.instructions = nil
            no_guidance.profile_instructions = false
            local empty = apply({instructions = ""}, no_guidance)
            test.is_nil(empty.instructions)
        end)

        test.it("does not mutate the policy or share preference containers", function()
            local host = policy()
            local source_options = host.prepare_options
            local source_tools = host.gateway_tools
            local raw_options = {model = "large"}
            local raw_tools = {"thread_read"}
            local value = apply({options = raw_options, mcp_tools = raw_tools, instructions = ""}, host)
            test.eq(source_options.model, "base")
            test.eq(source_tools[1], "thread_wait")
            test.neq(value.prepare_options, source_options)
            test.neq(value.gateway_tools, source_tools)
            raw_options.model = "small"
            raw_tools[1] = "thread_wait"
            test.eq(value.prepare_options.model, "large")
            test.eq(value.gateway_tools[1], "thread_read")
            test.eq(value.retained, host.retained)
        end)
    end)
end

return test.run_cases(define_tests)
