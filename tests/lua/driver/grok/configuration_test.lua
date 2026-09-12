-- MIT. Grok configuration tests: projection of .grok/config.toml,
-- strict rejection of provider configuration and gateway hooks,
-- and deterministic SHA-256 measurement.
local test = require("test")
local configuration = require("configuration")
local configure = require("configure")

local function define_tests()
    test.describe("Grok configuration", function()
        test.it("renders gateway TOML with permission rules and MCP server", function()
            local gateway: configuration.Gateway = {
                endpoint = "127.0.0.1:4321",
                action_id = "act-test-123",
                tools = {"read_file", "write_file"},
                hooks = {},
                token_environment = "BEE_GATEWAY_TOKEN",
            }
            local toml = configuration.render_gateway(gateway)
            test.is_true(toml:find("[permission]", 1, true) ~= nil)
            test.is_true(toml:find('"MCPTool(bee__*)"', 1, true) ~= nil)
            test.is_true(toml:find("[mcp_servers.bee]", 1, true) ~= nil)
            test.is_true(toml:find('url = "http://127.0.0.1:4321/mcp/act-test-123"', 1, true) ~= nil)
            test.is_true(toml:find("enabled = true", 1, true) ~= nil)
            test.is_true(toml:find("[mcp_servers.bee.headers]", 1, true) ~= nil)
            test.is_true(toml:find('Authorization = "Bearer ${BEE_GATEWAY_TOKEN}"', 1, true) ~= nil)
        end)

        test.it("produces a valid, deterministic projection", function()
            local gateway: configuration.Gateway = {
                endpoint = "127.0.0.1:8080",
                action_id = "act-proj-1",
                tools = {"tool_one"},
                hooks = {},
                token_environment = "GATEWAY_TOKEN",
            }
            local proj, err = configuration.projection(gateway)
            if not proj then error(tostring(err)) end
            test.eq(proj.revision, "bee.grok-config@1")
            test.eq(proj.path, ".grok/config.toml")
            test.eq(proj.provider_ref, "bee:gateway_endpoint")
            test.eq(#proj.digest, 64)

            -- Deterministic digest
            local again, err2 = configuration.projection(gateway)
            if not again then error(tostring(err2)) end
            test.eq(again.digest, proj.digest)

            -- Different action_id changes digest
            gateway.action_id = "act-proj-2"
            local changed, err3 = configuration.projection(gateway)
            if not changed then error(tostring(err3)) end
            test.neq(changed.digest, proj.digest)
        end)

        test.it("rejects oversized configuration exceeding MAX_CONFIGURATION_BYTES", function()
            local gateway: configuration.Gateway = {
                endpoint = "127.0.0.1:8080",
                action_id = string.rep("x", configuration.MAX_CONFIGURATION_BYTES + 10),
                tools = {"t"},
                hooks = {},
                token_environment = "TOKEN",
            }
            local proj, err = configuration.projection(gateway)
            test.is_nil(proj)
            test.is_true(err:find("exceeds", 1, true) ~= nil)
        end)

        test.it("configure method delivers projected files and rejects provider configuration", function()
            -- Succeeded delivery with gateway
            local req = {
                fixture = false,
                gateway = {
                    endpoint = "127.0.0.1:9090",
                    action_id = "action-alpha",
                    tools = {"tool_a"},
                    hooks = {},
                    token_environment = "BEE_TOKEN",
                },
            }
            local reply = configure.handle(req)
            test.is_true(reply.ok)
            local delivery = reply.delivery :: {[string]: unknown}
            test.not_nil(delivery)
            local files = delivery.files :: {{[string]: unknown}}
            test.eq(#files, 1)
            test.eq(files[1].path, ".grok/config.toml")
            test.eq(files[1].revision, "bee.grok-config@1")
            test.eq(files[1].provider_ref, "bee:gateway_endpoint")

            -- Empty delivery when gateway is nil
            local empty_req = {fixture = false}
            local empty_reply = configure.handle(empty_req)
            test.is_true(empty_reply.ok)
            local empty_del = empty_reply.delivery :: {[string]: unknown}
            test.eq(#(empty_del.files :: {unknown}), 0)
            test.eq(#(empty_del.arguments :: {unknown}), 0)

            -- Rejects provider configuration
            local provider_req = {
                fixture = false,
                provider_ref = "custom:provider",
                provider = {schema_revision = "bee.codex-provider@1"},
            }
            local provider_reply = configure.handle(provider_req)
            test.is_false(provider_reply.ok)
            test.eq(provider_reply.error, "grok accepts no provider configuration")

            -- Rejects gateway hooks
            local hooks_req = {
                fixture = false,
                gateway = {
                    endpoint = "127.0.0.1:9090",
                    action_id = "action-alpha",
                    tools = {"tool_a"},
                    hooks = {"SessionStart"},
                    token_environment = "BEE_TOKEN",
                    hook_token_environment = "BEE_HOOK_TOKEN",
                },
            }
            local hooks_reply = configure.handle(hooks_req)
            test.is_false(hooks_reply.ok)
            test.eq(hooks_reply.error, "grok accepts no gateway hooks")
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
