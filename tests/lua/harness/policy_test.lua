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
