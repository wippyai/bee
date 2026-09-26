-- MIT. OpenCode configuration: one composed opencode.json with the scoped
-- bee remote MCP entry, strict refusal of providers, instructions and hook
-- events, and deterministic SHA-256 measurement.
local test = require("test")
local json = require("json")
local registry = require("registry")
local configuration = require("configuration")
local configure = require("configure")
local placement_configuration = require("placement_configuration")
local placement_types = require("placement_types")
local function gateway(tools: {string}, hooks: {string}): configuration.Gateway
    return {endpoint = "127.0.0.1:4312", action_id = "action-1", tools = tools, hooks = hooks,
        token_environment = "BEE_GATEWAY_TOKEN"}
end
local function define_tests()
    test.describe("OpenCode configuration", function()
        test.it("declares no hook transport on either shipped route", function()
            for _, ref in ipairs({"bee:launch_policy_opencode_window", "bee:launch_policy_opencode_batch"}) do
                local entry, entry_error = registry.get(ref)
                if not entry then error(tostring(entry_error or (ref .. " is missing"))) end
                local data = entry.data :: {[string]: unknown}
                test.eq(#(data.gateway_hooks :: {unknown}), 0)
                test.is_nil(data.hook_command_ref)
            end
        end)
        test.it("renders one composed config file with the scoped bee remote entry", function()
            local file, err = configuration.settings_file(gateway({"thread_read"}, {}))
            if not file then error(tostring(err)) end
            test.eq(file.revision, "bee.opencode-config@1")
            test.eq(file.path, ".config/opencode/opencode.json")
            test.eq(file.provider_ref, "bee:gateway_endpoint")
            local composition = assert(file.composition)
            test.eq(composition.kind, "json_patch")
            test.eq(composition.base_path, ".config/opencode/.bee-global-opencode.json")
            test.eq(composition.operations[1].kind, "default")
            test.eq(composition.operations[1].path[1], "$schema")
            test.eq(composition.operations[2].kind, "insert")
            test.eq(composition.operations[2].path[1], "mcp")
            test.eq(composition.operations[2].path[2], "bee")
            local document = assert(json.decode(file.content))
            test.eq(document["$schema"], "https://opencode.ai/config.json")
            local bee = assert(document.mcp.bee)
            test.eq(bee.type, "remote")
            test.eq(bee.url, "http://127.0.0.1:4312/mcp/action-1")
            test.eq(bee.enabled, true)
            test.eq(bee.headers.Authorization, "")
            test.is_nil(file.content:find("BEE_GATEWAY_TOKEN", 1, true))
            local secrets = assert(file.secret_fields)
            test.eq(#secrets, 1)
            test.eq(secrets[1].environment, "BEE_GATEWAY_TOKEN")
            test.eq(secrets[1].prefix, "Bearer ")
            test.eq(#file.digest, 64)
            local again = assert(configuration.settings_file(gateway({"thread_read"}, {})))
            test.eq(again.digest, file.digest)
        end)
        test.it("composes the bee entry from the frozen base without replacing user configuration", function()
            local file = assert(configuration.settings_file(gateway({"thread_read"}, {})))
            local selected: placement_types.Gateway = {endpoint = "127.0.0.1:4312", tools = {"thread_read"}, hooks = {},
                destination = "BEE_GATEWAY_TOKEN"}
            local base = [[{"$schema":"https://opencode.ai/config.json","model":"user/model","mcp":{"other":{"type":"remote","url":"http://other"}}}}]]
            local rendered, render_error = placement_configuration.render(file, {BEE_GATEWAY_TOKEN = "private-token"}, selected, base)
            if not rendered then error(tostring(render_error)) end
            local document = assert(json.decode(rendered))
            test.eq(document.model, "user/model")
            test.eq(document.mcp.other.url, "http://other")
            test.eq(document.mcp.bee.url, "http://127.0.0.1:4312/mcp/action-1")
            test.eq(document.mcp.bee.headers.Authorization, "Bearer private-token")
            local again, again_error = placement_configuration.render(file, {BEE_GATEWAY_TOKEN = "private-token"}, selected, base)
            if not again then error(tostring(again_error)) end
            test.eq(again, rendered)
        end)
        test.it("refuses hook events, providers and instructions", function()
            local _, event_error = configuration.settings_file(gateway({"thread_read"}, {"Stop"}))
            test.eq(event_error, "opencode does not support gateway hook event Stop")
            local hook_reply = configure.handle({fixture = false,
                gateway = {endpoint = "127.0.0.1:4312", action_id = "action-1", tools = {"thread_read"},
                    hooks = {"Stop"}, token_environment = "BEE_GATEWAY_TOKEN",
                    hook_token_environment = "BEE_HOOK_TOKEN"}})
            test.is_false(hook_reply.ok)
            test.eq(hook_reply.error, "opencode does not support gateway hook event Stop")
            local provider_reply = configure.handle({fixture = false, provider_ref = "custom:provider",
                provider = {schema_revision = "bee.opencode-provider@1"}})
            test.is_false(provider_reply.ok)
            test.eq(provider_reply.error, "opencode configures no model provider; the user selects models in their own OpenCode home")
            local instructions_reply = configure.handle({fixture = false, instructions = "Answer tersely."})
            test.is_false(instructions_reply.ok)
            test.eq(instructions_reply.error, "opencode accepts no profile instructions")
        end)
        test.it("delivers the config file with tools and an empty delivery without", function()
            local reply = configure.handle({fixture = false,
                gateway = {endpoint = "127.0.0.1:4312", action_id = "action-1", tools = {"thread_read"},
                    hooks = {}, token_environment = "BEE_GATEWAY_TOKEN"}})
            test.is_true(reply.ok)
            local delivery = reply.delivery :: {[string]: unknown}
            local files = delivery.files :: {{[string]: unknown}}
            test.eq(#files, 1)
            test.eq(files[1].path, ".config/opencode/opencode.json")
            test.eq(#(delivery.arguments :: {unknown}), 0)
            local empty = configure.handle({fixture = false})
            test.is_true(empty.ok)
            test.eq(#((empty.delivery :: {[string]: unknown}).files :: {unknown}), 0)
        end)
    end)
end
return test.run_cases(define_tests)
