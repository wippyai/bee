-- MIT. Untrusted saved preferences cannot smuggle host authority or unbounded data.
local test = require("test")
local protocol = require("protocol")
local function define_tests()
    test.describe("Saved agent profile boundary", function()
        test.it("decodes and forwards one bounded Bee permission answer preference", function()
            for _, mode in ipairs({"provider", "ask", "deny"}) do
                local profile = assert(protocol.profile({schema_revision = "bee.agent-profile@2", name = "Permission", definition_ref = "bee:claude", driver_binding_ref = "bee.driver.claude.binding:binding", provider = {}, bee = {permission_answers = mode, mcp = {}}}))
                local preferences = assert(protocol.agent_preferences(profile, {}))
                test.eq(preferences.bee and preferences.bee.permission_answers, mode)
            end
            for _, value in ipairs({{permission_answers = "bypass"}, {permission_answers = true}, {permission_answers = "deny", executable = "sh"}}) do
                test.eq(protocol.profile({schema_revision = "bee.agent-profile@2", name = "Permission", definition_ref = "bee:claude", driver_binding_ref = "bee.driver.claude.binding:binding", provider = {}, bee = value}), nil)
            end
        end)
        test.it("copies preferences without sharing caller-owned maps", function()
            local options = {model = "small", verbose = false, temperature = 0.5}
            local tools = {"bee.threads:read"}
            local value, err = protocol.profile({schema_revision = "bee.agent-profile@2", name = "My Codex", definition_ref = "bee:codex", driver_binding_ref = "bee.driver.codex.binding:binding", provider = {model = options.model, options = {verbose = options.verbose, temperature = options.temperature}, system_prompt_append = "Keep changes small.\nUse tests."}, bee = {mcp = {{tool = tools[1], scope = {}}}}})
            if not value then error(tostring(err)) end
            options.model = "changed"
            tools[1] = "different"
            test.eq(value.provider.model, "small")
            test.eq(value.bee.mcp[1].tool, "bee.threads:read")
            test.eq(value.provider.options.verbose, false)
        end)
        test.it("refuses authority fields rather than silently ignoring them", function()
            for _, field in ipairs({"executable", "credentials", "endpoint", "environment", "permissions", "owner_id", "instruction_builder", "provider_ref", "isolation", "config_profile"}) do
                local raw: {[string]: unknown} = {schema_revision = "bee.agent-profile@2", name = "Custom", definition_ref = "bee:codex", driver_binding_ref = "bee.driver.codex.binding:binding", provider = {}, bee = {mcp = {}}}
                raw[field] = "untrusted"
                local value = protocol.profile(raw)
                test.is_nil(value)
            end
        end)
        test.it("bounds option values and rejects nested or nonfinite values", function()
            for _, option in ipairs({{nested = true}, math.huge, -math.huge, string.rep("x", 513), "bad\0value"}) do
                local value = protocol.profile({schema_revision = "bee.agent-profile@2", name = "Custom", definition_ref = "bee:codex", driver_binding_ref = "bee.driver.codex.binding:binding", provider = {model = option}, bee = {mcp = {}}})
                test.is_nil(value)
            end
            local value = protocol.profile({schema_revision = "bee.agent-profile@2", name = "Custom", definition_ref = "bee:codex", driver_binding_ref = "bee.driver.codex.binding:binding", provider = {model = 0/0}, bee = {mcp = {}}})
            test.is_nil(value)
        end)
        test.it("bounds instructions and rejects duplicate MCP tools", function()
            for _, instructions in ipairs({string.rep("x", 4097), "escape\27sequence", "delete\127"}) do
                local value = protocol.profile({schema_revision = "bee.agent-profile@2", name = "Custom", definition_ref = "bee:codex", driver_binding_ref = "bee.driver.codex.binding:binding", provider = {system_prompt_append = instructions}, bee = {mcp = {}}})
                test.is_nil(value)
            end
            local duplicate = protocol.profile({schema_revision = "bee.agent-profile@2", name = "Custom", definition_ref = "bee:codex", driver_binding_ref = "bee.driver.codex.binding:binding", provider = {}, bee = {mcp = {{tool = "tool", scope = {}}, {tool = "tool", scope = {}}}}})
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
        test.it("stores agent reference, owner component revision and spec digest in workspace state", function()
            local valid_digest = string.rep("a", 64)
            local value, err = protocol.profile({schema_revision = "bee.agent-profile@2", name = "Research Assistant", definition_ref = "bee:codex", driver_binding_ref = "bee.driver.codex.binding:binding", provider = {options = {verbose = true}, system_prompt_append = "Assist with research."}, bee = {mcp = {}} , agent_ref = "bee.agents:researcher", owner_component_revision = 3, spec_digest = valid_digest})
            if not value then error(tostring(err)) end
            test.eq(value.agent_ref, "bee.agents:researcher")
            test.eq(value.owner_component_revision, 3)
            test.eq(value.spec_digest, valid_digest)

            local canonical, canonical_err = protocol.profile({schema_revision = "bee.agent-profile@2", name = "Research Assistant", definition_ref = "bee:codex", driver_binding_ref = "bee.driver.codex.binding:binding", provider = {}, bee = {mcp = {}} , owner_component_revision = 2})
            if not canonical then error(tostring(canonical_err)) end
            test.eq(canonical.owner_component_revision, 2)
            local _, alias_err = protocol.profile({schema_revision = "bee.agent-profile@2", name = "Research Assistant", definition_ref = "bee:codex", driver_binding_ref = "bee.driver.codex.binding:binding", provider = {}, bee = {mcp = {}} , owner_revision = 2})
            test.eq(alias_err, "unknown field owner_revision")
        end)
        test.it("refuses malformed agent reference, owner component revision or spec digest", function()
            local _, bad_ref = protocol.profile({schema_revision = "bee.agent-profile@2", name = "P", definition_ref = "bee:codex", driver_binding_ref = "bee.driver.codex.binding:binding", provider = {}, bee = {mcp = {}} , agent_ref = "bad\0ref"})
            test.eq(bad_ref, "agent_ref must be an identifier")

            for _, bad_rev in ipairs({0, -1, 1.5, "1", math.huge}) do
                local _, err = protocol.profile({schema_revision = "bee.agent-profile@2", name = "P", definition_ref = "bee:codex", driver_binding_ref = "bee.driver.codex.binding:binding", provider = {}, bee = {mcp = {}} , owner_component_revision = bad_rev})
                test.eq(err, "owner_component_revision must be a positive integer")
            end

            for _, bad_digest in ipairs({
                "short",
                string.rep("A", 64),
                string.rep("g", 64),
                string.rep("a", 65),
                12345
            }) do
                local _, err = protocol.profile({schema_revision = "bee.agent-profile@2", name = "P", definition_ref = "bee:codex", driver_binding_ref = "bee.driver.codex.binding:binding", provider = {}, bee = {mcp = {}} , spec_digest = bad_digest})
                test.eq(err, "spec_digest must be a lowercase SHA-256 hex digest")
            end
        end)
        test.it("enforces expected revision and idempotency for concurrent edits and retries", function()
            local put_req, err = protocol.decode({
                operation = "put",
                workspace_id = "workspace",
                profile_id = "agent_profile",
                expected_revision = 2,
                idempotency_key = "retry_edit_1",
                profile = {schema_revision = "bee.agent-profile@2", name = "Worker", definition_ref = "bee:codex", driver_binding_ref = "bee.driver.codex.binding:binding", provider = {}, bee = {mcp = {}} , agent_ref = "bee.agents:worker", owner_component_revision = 1, spec_digest = string.rep("e", 64)}
            })
            if not put_req then error(tostring(err)) end
            test.eq(put_req.expected_revision, 2)
            test.eq(put_req.idempotency_key, "retry_edit_1")
            test.eq(put_req.profile and put_req.profile.owner_component_revision, 1)

            local rem_req, rem_err = protocol.decode({
                operation = "remove",
                workspace_id = "workspace",
                profile_id = "agent_profile",
                expected_revision = 3,
                idempotency_key = "retry_remove_1"
            })
            if not rem_req then error(tostring(rem_err)) end
            test.eq(rem_req.expected_revision, 3)
        end)
        test.it("refuses cross-workspace or invalid workspace identities", function()
            local _, bad_ws = protocol.decode({
                operation = "get",
                workspace_id = "bad\0workspace",
                profile_id = "profile"
            })
            test.eq(bad_ws, "workspace_id must be an identifier")
        end)
    end)
end
return test.run_cases(define_tests)
