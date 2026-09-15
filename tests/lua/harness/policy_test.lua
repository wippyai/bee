-- MIT. Host policy resolves declared executable variables at the policy
-- boundary, fences their values in its digest, and refuses unavailable names.
local test = require("test")
local policy = require("policy")

type Entry = {[string]: unknown}
type Resolver = (string) -> (string?, string?)

local function entry(executables: {[string]: string}, executable_env: {[string]: string}?): Entry
    return {id = "test:policy", kind = "registry.entry", meta = {type = "bee.launch_policy"}, data = {
        schema_revision = "bee.launch-policy@2",
        required_cleanup = "direct_process",
        required_exit_observation = "eof_gated",
        fixture = true,
        executables = executables,
        executable_env = executable_env,
        environment = {},
    }}
end

local function resolve(values: {[string]: string}): Resolver
    return function(ref: string): (string?, string?)
        local value = values[ref]
        if value == nil then return nil, "not found" end
        return value, nil
    end
end

local function define_tests()
    test.describe("Launch-policy executable environment", function()
        test.it("measures MCP context and traits without retaining mutable host tables", function()
            local raw = entry({sh = "/bin/sh"})
            local data = raw.data :: Entry
            local fixed = {project = "one"}
            data.gateway_tools = {"thread_read"}
            data.gateway_surface = {tools = {}, traits = {{id = "docs:reader", title = "Reader", prompt = "Read first", tools = {"thread_read"}}},
                base_tools = {}, active_traits = {"docs:reader"}, fixed_context = fixed, dynamic_keys = {"experiment"}}
            local first, err = policy.decode("test:policy", raw)
            if not first or not first.gateway_surface then error(tostring(err)) end
            fixed.project = "two"
            test.eq((first.gateway_surface.fixed_context :: Entry).project, "one")
            local changed = policy.decode("test:policy", raw)
            if not changed then error("changed surface") end
            test.neq(first.digest, changed.digest)
            data.gateway_tools = {}
            test.is_nil(policy.decode("test:policy", raw))
        end)
        test.it("inherits only selected nonempty environment values and fences changes", function()
            local raw = entry({sh = "/bin/sh"})
            local data = raw.data :: Entry
            data.environment_refs = {CODEX_HOME = "test:config_home", CLAUDE_CONFIG_DIR = "test:absent"}
            local first, first_error = policy.decode("test:policy", raw, resolve({["test:config_home"] = "/custom/codex", ["test:absent"] = ""}))
            if not first then error(tostring(first_error)) end
            test.eq(first.environment.CODEX_HOME, "/custom/codex")
            test.is_nil(first.environment.CLAUDE_CONFIG_DIR)
            test.eq(first.host_environment.CODEX_HOME, "/custom/codex")
            test.is_nil(first.host_environment.CLAUDE_CONFIG_DIR)
            local changed, changed_error = policy.decode("test:policy", raw, resolve({["test:config_home"] = "/other/codex", ["test:absent"] = ""}))
            if not changed then error(tostring(changed_error)) end
            test.neq(first.digest, changed.digest)
            local missing = policy.decode("test:policy", raw, resolve({}))
            test.is_nil(missing)
            data.environment = {CODEX_HOME = "/literal"}
            local collision = policy.decode("test:policy", raw, resolve({["test:config_home"] = "/custom/codex", ["test:absent"] = ""}))
            test.is_nil(collision)
        end)
        test.it("pins component options with the explicitly selected placement", function()
            local raw = entry({sh = "/bin/sh"})
            local data = raw.data :: Entry
            data.placement_options = {image = "one", user = "1000:1000"}
            local missing = policy.decode("test:policy", raw)
            test.is_nil(missing)
            data.placement_binding = "test:placement"
            local first, first_error = policy.decode("test:policy", raw)
            if not first then error(tostring(first_error)) end
            test.eq(first.placement_binding, "test:placement")
            local options = first.placement_options
            if not options then error("placement options were discarded") end
            test.eq(options.image, "one")
            data.placement_options = {image = "two", user = "1000:1000"}
            local changed, changed_error = policy.decode("test:policy", raw)
            if not changed then error(tostring(changed_error)) end
            test.neq(first.digest, changed.digest)
            data.placement_options = "untyped"
            local invalid = policy.decode("test:policy", raw)
            test.is_nil(invalid)
        end)
        test.it("makes host HOME an explicit measured host decision", function()
            local raw = entry({sh = "/bin/sh"})
            local denied, denied_error = policy.decode("test:policy", raw)
            if not denied then error(tostring(denied_error)) end
            test.eq(denied.allow_host_home, false)
            local denied_digest = denied.digest
            local data = raw.data :: Entry
            data.allow_host_home = true
            local allowed, allowed_error = policy.decode("test:policy", raw)
            if not allowed then error(tostring(allowed_error)) end
            test.eq(allowed.allow_host_home, true)
            test.neq(allowed.digest, denied_digest)
            data.allow_host_home = "true"
            local invalid, invalid_error = policy.decode("test:policy", raw)
            test.is_nil(invalid)
            test.eq(invalid_error, "test:policy: allow_host_home must be a boolean")
        end)

        test.it("keeps the host authority digest while applying admitted preferences", function()
            local raw = entry({claude = "/bin/claude"})
            local data = raw.data :: Entry
            data.prepare_options = {max_turns = 1}
            data.profile_options = {max_turns = {1, 3}}
            data.profile_instructions = true
            data.instructions = "Host instructions"
            local host, host_error = policy.decode("test:policy", raw)
            if not host then error(tostring(host_error)) end
            local selected, selected_error = policy.decode("test:policy", raw, nil, {options = {max_turns = 3}, mcp_tools = {}, instructions = "Profile instructions"})
            if not selected then error(tostring(selected_error)) end
            test.eq(host.digest, selected.digest)
            test.eq(host.prepare_options.max_turns, 1)
            test.eq(selected.prepare_options.max_turns, 3)
            test.eq(selected.instructions, "Host instructions\n\nProfile instructions")
            test.eq(selected.executables.claude, host.executables.claude)
        end)
        test.it("measures hooks independently from the MCP tool grant", function()
            local raw = entry({claude = "/bin/claude"})
            local data = raw.data :: Entry
            data.gateway_tools = {}
            data.gateway_hooks = {"SessionStart"}
            local decoded, err = policy.decode("test:policy", raw)
            if not decoded then error(tostring(err)) end
            test.eq(#decoded.gateway_tools, 0)
            test.eq(decoded.gateway_hooks[1], "SessionStart")
            data.gateway_hooks = {}
            local disabled, disabled_error = policy.decode("test:policy", raw)
            if not disabled then error(tostring(disabled_error)) end
            test.neq(decoded.digest, disabled.digest)
        end)
        test.it("pins the resolved executable value in the policy digest", function()
            local first, first_error = policy.decode("test:policy", entry({}, {claude = "test:claude"}), resolve({["test:claude"] = "/opt/one/claude"}))
            if not first then error(tostring(first_error)) end
            local second, second_error = policy.decode("test:policy", entry({}, {claude = "test:claude"}), resolve({["test:claude"] = "/opt/two/claude"}))
            if not second then error(tostring(second_error)) end
            test.eq(first.executables.claude, "/opt/one/claude")
            test.eq(second.executables.claude, "/opt/two/claude")
            test.neq(first.digest, second.digest)
        end)

        test.it("refuses missing or denied executable variables", function()
            for _, resolver in ipairs({
                resolve({}),
                function(_: string): (string?, string?) return nil, "denied" end,
            }) do
                local decoded, decode_error = policy.decode("test:policy", entry({}, {claude = "test:claude"}), resolver)
                test.is_nil(decoded)
                test.eq(decode_error, "test:policy: executable_env.claude is unavailable from test:claude")
            end
        end)

        test.it("rejects an executable that has both literal and environment bindings", function()
            local decoded, decode_error = policy.decode("test:policy", entry({claude = "/bin/claude"}, {claude = "test:claude"}), resolve({["test:claude"] = "/opt/claude"}))
            test.is_nil(decoded)
            test.eq(decode_error, "test:policy: executable_env.claude overlaps executables")
        end)
    end)
end

return test.run_cases(define_tests)
