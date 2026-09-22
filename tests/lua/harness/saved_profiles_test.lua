-- MIT. Untrusted saved preferences cannot smuggle host authority or unbounded data.
local test = require("test")
local protocol = require("protocol")
local function define_tests()
    test.describe("Saved agent profile boundary", function()
        test.it("copies preferences without sharing caller-owned maps", function()
            local options = {model = "small", verbose = false, temperature = 0.5}
            local tools = {"bee.threads:read"}
            local value, err = protocol.profile({title = "My Codex", definition_ref = "bee:codex", options = options, mcp_tools = tools, instructions = "Keep changes small.\nUse tests."})
            if not value then error(tostring(err)) end
            options.model = "changed"
            tools[1] = "different"
            test.eq(value.options.model, "small")
            test.eq(value.mcp_tools[1], "bee.threads:read")
            test.eq(value.options.verbose, false)
        end)
        test.it("refuses authority fields rather than silently ignoring them", function()
            for _, field in ipairs({"executable", "credentials", "endpoint", "environment", "permissions", "owner_id", "instruction_builder", "provider_ref", "isolation", "config_profile"}) do
                local raw: {[string]: unknown} = {title = "Custom", definition_ref = "bee:codex"}
                raw[field] = "untrusted"
                local value = protocol.profile(raw)
                test.is_nil(value)
            end
        end)
        test.it("bounds option values and rejects nested or nonfinite values", function()
            for _, option in ipairs({{nested = true}, math.huge, -math.huge, string.rep("x", 513), "bad\0value"}) do
                local value = protocol.profile({title = "Custom", definition_ref = "bee:codex", options = {model = option}})
                test.is_nil(value)
            end
            local value = protocol.profile({title = "Custom", definition_ref = "bee:codex", options = {model = 0/0}})
            test.is_nil(value)
        end)
        test.it("bounds instructions and rejects duplicate MCP tools", function()
            for _, instructions in ipairs({string.rep("x", 4097), "escape\27sequence", "delete\127"}) do
                local value = protocol.profile({title = "Custom", definition_ref = "bee:codex", instructions = instructions})
                test.is_nil(value)
            end
            local duplicate = protocol.profile({title = "Custom", definition_ref = "bee:codex", mcp_tools = {"tool", "tool"}})
            test.is_nil(duplicate)
        end)
        test.it("requires a pinned cursor to continue a profile snapshot", function()
            local unpinned = protocol.decode({operation = "list", workspace_id = "workspace", after_key = "profile"})
            test.is_nil(unpinned)
            local pinned, err = protocol.decode({operation = "list", workspace_id = "workspace", after_key = "profile", expected_cursor = 0, limit = 64})
            if not pinned then error(tostring(err)) end
            test.eq(pinned.expected_cursor, 0)
            local first, first_error = protocol.decode({operation = "list", workspace_id = "workspace"})
            if not first then error(tostring(first_error)) end
            test.eq(first.limit, 32)
            test.eq(first.after_key, "")
        end)
        test.it("requires revision and retry identity for edits", function()
            local invalid = protocol.decode({operation = "remove", workspace_id = "workspace", profile_id = "profile"})
            test.is_nil(invalid)
            local valid, err = protocol.decode({operation = "remove", workspace_id = "workspace", profile_id = "profile", expected_revision = 0, idempotency_key = "retry"})
            if not valid then error(tostring(err)) end
            test.eq(valid.expected_revision, 0)
            local overreach = protocol.decode({operation = "get", workspace_id = "workspace", profile_id = "profile", resource = "foreign"})
            test.is_nil(overreach)
        end)
    end)
end
return test.run_cases(define_tests)
