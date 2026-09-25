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
        test.it("stores agent reference, owner component revision and spec digest in workspace state", function()
            local valid_digest = string.rep("a", 64)
            local value, err = protocol.profile({
                title = "Research Assistant",
                definition_ref = "bee:codex",
                agent_ref = "bee.agents:researcher",
                owner_component_revision = 3,
                spec_digest = valid_digest,
                options = {verbose = true},
                mcp_tools = {},
                instructions = "Assist with research."
            })
            if not value then error(tostring(err)) end
            test.eq(value.agent_ref, "bee.agents:researcher")
            test.eq(value.owner_component_revision, 3)
            test.eq(value.spec_digest, valid_digest)

            local aliased, alias_err = protocol.profile({
                title = "Research Assistant",
                definition_ref = "bee:codex",
                owner_revision = 2,
            })
            if not aliased then error(tostring(alias_err)) end
            test.eq(aliased.owner_component_revision, 2)
        end)
        test.it("refuses malformed agent reference, owner component revision or spec digest", function()
            local _, bad_ref = protocol.profile({title = "P", definition_ref = "bee:codex", agent_ref = "not an id!"})
            test.eq(bad_ref, "agent_ref must be an identifier")

            for _, bad_rev in ipairs({0, -1, 1.5, "1", math.huge}) do
                local _, err = protocol.profile({title = "P", definition_ref = "bee:codex", owner_component_revision = bad_rev})
                test.eq(err, "owner_component_revision must be a positive integer")
            end

            for _, bad_digest in ipairs({
                "short",
                string.rep("A", 64),
                string.rep("g", 64),
                string.rep("a", 65),
                12345
            }) do
                local _, err = protocol.profile({title = "P", definition_ref = "bee:codex", spec_digest = bad_digest})
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
                profile = {
                    title = "Worker",
                    definition_ref = "bee:codex",
                    agent_ref = "bee.agents:worker",
                    owner_component_revision = 1,
                    spec_digest = string.rep("e", 64)
                }
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
                workspace_id = "not a valid id!",
                profile_id = "profile"
            })
            test.eq(bad_ws, "workspace_id must be an identifier")
        end)
    end)
end
return test.run_cases(define_tests)
