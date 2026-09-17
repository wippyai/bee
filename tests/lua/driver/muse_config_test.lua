-- MIT. Muse configuration: one private settings.json with the scoped MCP
-- server and command hooks, strict rejection of provider configuration
-- and profile instructions, and deterministic SHA-256 measurement.
local test = require("test")
local json = require("json")
local configuration = require("configuration")
local configure = require("configure")
local function gateway(tools: {string}, hooks: {string}): configuration.Gateway
    return {endpoint = "127.0.0.1:4312", action_id = "action-1", tools = tools, hooks = hooks,
        token_environment = "BEE_GATEWAY_TOKEN", hook_token_environment = "BEE_HOOK_TOKEN",
        hook_command = "/abs/bee-hook"}
end
local function define_tests()
    test.describe("Muse configuration", function()
        test.it("renders one settings file with scoped MCP and command hooks", function()
            local file, err = configuration.settings_file(gateway({"thread_read"}, {"SessionStart"}))
            if not file then error(tostring(err)) end
            test.eq(file.revision, "bee.muse-config@1")
            test.eq(file.path, "muse/settings.json")
            test.eq(file.provider_ref, "bee:gateway_endpoint")
            local document = assert(json.decode(file.content))
            test.eq(document.schema_version, 1)
            local servers = assert(document.mcpServers)
            test.eq(servers.bee.url, "http://127.0.0.1:4312/mcp/action-1")
            test.eq(servers.bee.headers.Authorization, "")
            local hooks = assert(document.hooks)
            local handlers = assert(hooks.SessionStart)
            test.eq(#handlers, 1)
            local handler = assert(handlers[1].hooks[1])
            test.eq(handler.type, "command")
            test.eq(handler.timeout, 3)
            test.is_true(handler.command:find("hook-post 127.0.0.1:4312 action-1 BEE_HOOK_TOKEN SessionStart", 1, true) ~= nil)
            test.is_nil(file.content:find("BEE_GATEWAY_TOKEN", 1, true))
            local secrets = assert(file.secret_fields)
            test.eq(#secrets, 1)
            test.eq(secrets[1].environment, "BEE_GATEWAY_TOKEN")
            test.eq(secrets[1].prefix, "Bearer ")
            test.eq(#file.digest, 64)
            local again = assert(configuration.settings_file(gateway({"thread_read"}, {"SessionStart"})))
            test.eq(again.digest, file.digest)
            local changed = assert(configuration.settings_file(gateway({"thread_read"}, {"Stop"})))
            test.neq(changed.digest, file.digest)
        end)
        test.it("renders tools-only and hooks-only settings without empty sections", function()
            local tools_only = assert(configuration.settings_file(gateway({"thread_read"}, {})))
            local tools_document = assert(json.decode(tools_only.content))
            test.not_nil(tools_document.mcpServers)
            test.is_nil(tools_document.hooks)
            local hooks_only = assert(configuration.settings_file(gateway({}, {"Stop"})))
            local hooks_document = assert(json.decode(hooks_only.content))
            test.is_nil(hooks_document.mcpServers)
            test.is_nil(hooks_document.secret_fields)
            test.not_nil(hooks_document.hooks.Stop)
        end)
        test.it("rejects gateway hooks Muse cannot deliver and unbound hook commands", function()
            local _, event_error = configuration.settings_file(gateway({"thread_read"}, {"SessionEnd2"}))
            test.eq(event_error, "muse does not support gateway hook event SessionEnd2")
            local unbound = gateway({}, {"SessionStart"})
            unbound.hook_command = nil
            local _, command_error = configuration.settings_file(unbound)
            test.eq(command_error, "muse hooks require the host-selected hook command")
            local uncredited = gateway({}, {"SessionStart"})
            uncredited.hook_token_environment = nil
            local _, token_error = configuration.settings_file(uncredited)
            test.eq(token_error, "muse hooks require a separate hook credential environment")
        end)
        test.it("delivers the settings file and refuses providers and instructions", function()
            local reply = configure.handle({fixture = false,
                gateway = {endpoint = "127.0.0.1:4312", action_id = "action-1", tools = {"thread_read"},
                    hooks = {"SessionStart"}, token_environment = "BEE_GATEWAY_TOKEN",
                    hook_token_environment = "BEE_HOOK_TOKEN", hook_command = "/abs/bee-hook"}})
            test.is_true(reply.ok)
            local delivery = reply.delivery :: {[string]: unknown}
            local files = delivery.files :: {{[string]: unknown}}
            test.eq(#files, 1)
            test.eq(files[1].path, "muse/settings.json")
            test.eq(#(delivery.arguments :: {unknown}), 0)
            local empty = configure.handle({fixture = false})
            test.is_true(empty.ok)
            test.eq(#((empty.delivery :: {[string]: unknown}).files :: {unknown}), 0)
            local provider_reply = configure.handle({fixture = false, provider_ref = "custom:provider",
                provider = {schema_revision = "bee.muse-provider@1"}})
            test.is_false(provider_reply.ok)
            test.eq(provider_reply.error, "muse accepts no provider configuration")
            local instructions_reply = configure.handle({fixture = false, instructions = "Answer tersely."})
            test.is_false(instructions_reply.ok)
            test.eq(instructions_reply.error, "muse accepts no profile instructions")
        end)
    end)
end
return test.run_cases(define_tests)
