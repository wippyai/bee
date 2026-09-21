-- MIT. Muse configuration: one private settings.json with the scoped MCP
-- server and command hooks, strict rejection of provider configuration
-- and profile instructions, and deterministic SHA-256 measurement.
local test = require("test")
local json = require("json")
local registry = require("registry")
local configuration = require("configuration")
local configure = require("configure")
local placement_configuration = require("placement_configuration")
local placement_types = require("placement_types")
local function gateway(tools: {string}, hooks: {string}): configuration.Gateway
    return {endpoint = "127.0.0.1:4312", action_id = "action-1", tools = tools, hooks = hooks,
        token_environment = "BEE_GATEWAY_TOKEN", hook_token_environment = "BEE_HOOK_TOKEN",
        hook_command = "/abs/bee-hook"}
end
local HOOK_SOURCE = "@/private/muse/.config/muse/.bee-hooks/attempt.json"
local function settings(tools: {string}, hooks: {string})
    return configuration.settings_file(gateway(tools, hooks), #hooks > 0 and HOOK_SOURCE or nil)
end
local function define_tests()
    test.describe("Muse configuration", function()
        test.it("binds the command hook executable on both shipped routes", function()
            for _, ref in ipairs({"bee:launch_policy_muse_window", "bee:launch_policy_muse_batch"}) do
                local entry, entry_error = registry.get(ref)
                if not entry then error(tostring(entry_error or (ref .. " is missing"))) end
                local data = entry.data :: {[string]: unknown}
                test.eq(data.hook_command_ref, "bee.gateway:hook_executable")
            end
        end)
        test.it("renders one settings file with scoped MCP and command hooks", function()
            local file, err = settings({"thread_read"}, {"SessionStart"})
            if not file then error(tostring(err)) end
            test.eq(file.revision, "bee.muse-config@1")
            test.eq(file.path, ".config/muse/settings.json")
            test.eq(file.provider_ref, "bee:gateway_endpoint")
            local composition = assert(file.composition)
            test.eq(composition.kind, "json_patch")
            test.eq(composition.base_path, ".config/muse/.bee-global-settings.json")
            test.eq(composition.operations[1].kind, "insert")
            test.eq(composition.operations[1].path[1], "mcpServers")
            test.eq(composition.operations[1].path[2], "bee")
            test.eq(composition.operations[2].kind, "default")
            test.eq(composition.operations[2].path[1], "schema_version")
            test.eq(composition.operations[3].kind, "append")
            test.eq(composition.operations[3].path[1], "hooks")
            test.eq(composition.operations[3].path[2], "SessionStart")
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
            test.is_true(handler.command:find("hook-post 127.0.0.1:4312 action-1 " .. HOOK_SOURCE .. " SessionStart", 1, true) ~= nil)
            test.is_nil(handler.command:find("BEE_HOOK_TOKEN", 1, true))
            test.is_nil(file.content:find("BEE_GATEWAY_TOKEN", 1, true))
            local secrets = assert(file.secret_fields)
            test.eq(#secrets, 1)
            test.eq(secrets[1].environment, "BEE_GATEWAY_TOKEN")
            test.eq(secrets[1].prefix, "Bearer ")
            test.eq(#file.digest, 64)
            local again = assert(settings({"thread_read"}, {"SessionStart"}))
            test.eq(again.digest, file.digest)
            local changed = assert(settings({"thread_read"}, {"Stop"}))
            test.neq(changed.digest, file.digest)
        end)
        test.it("composes Muse settings from the frozen base without replacing user settings", function()
            local file = assert(settings({"thread_read"}, {"SessionStart", "Stop"}))
            local selected: placement_types.Gateway = {endpoint = "127.0.0.1:4312", tools = {"thread_read"}, hooks = {"SessionStart", "Stop"},
                destination = "BEE_GATEWAY_TOKEN", hook_destination = "BEE_HOOK_TOKEN"}
            local base = [[{"schema_version":1,"provider":"host","model":"muse-pro","tui":{"theme":"dawn"},"mcpServers":{"other":{"url":"http://other"}},"hooks":{"SessionStart":[{"matcher":"user","hooks":[{"type":"command","command":"user-start"}]}],"Other":[{"hooks":[{"type":"command","command":"other"}]}]}}]]
            local rendered, render_error = placement_configuration.render(file, {BEE_GATEWAY_TOKEN = "private-token"}, selected, base)
            if not rendered then error(tostring(render_error)) end
            local document = assert(json.decode(rendered))
            test.eq(document.provider, "host")
            test.eq(document.model, "muse-pro")
            test.eq(document.tui.theme, "dawn")
            test.eq(document.mcpServers.other.url, "http://other")
            test.eq(document.mcpServers.bee.headers.Authorization, "Bearer private-token")
            test.eq(#document.hooks.SessionStart, 2)
            test.eq(document.hooks.SessionStart[1].matcher, "user")
            test.eq(document.hooks.SessionStart[2].hooks[1].timeout, 3)
            test.eq(#document.hooks.Stop, 1)
            test.eq(#document.hooks.Other, 1)
            local again, again_error = placement_configuration.render(file, {BEE_GATEWAY_TOKEN = "private-token"}, selected, base)
            if not again then error(tostring(again_error)) end
            test.eq(again, rendered)
        end)
        test.it("admits an empty Muse base and refuses malformed or conflicting retained settings", function()
            local file = assert(settings({"thread_read"}, {"Stop"}))
            local selected: placement_types.Gateway = {endpoint = "127.0.0.1:4312", tools = {"thread_read"}, hooks = {"Stop"},
                destination = "BEE_GATEWAY_TOKEN", hook_destination = "BEE_HOOK_TOKEN"}
            local empty, empty_error = placement_configuration.render(file, {BEE_GATEWAY_TOKEN = "private-token"}, selected, "")
            if not empty then error(tostring(empty_error)) end
            local document = assert(json.decode(empty))
            test.not_nil(document.mcpServers.bee)
            test.not_nil(document.hooks.Stop)
            for _, base in ipairs({"[ ]", "{", "{\"schema_version\":2}", "{\"mcpServers\":[]}", "{\"hooks\":{\"Stop\":{}}}",
                "{\"mcpServers\":{\"bee\":{\"url\":\"http://user\"}}}"}) do
                local refused = placement_configuration.render(file, {BEE_GATEWAY_TOKEN = "private-token"}, selected, base)
                test.is_nil(refused)
            end
        end)
        test.it("renders tools-only and hooks-only settings without empty sections", function()
            local tools_only = assert(settings({"thread_read"}, {}))
            local tools_document = assert(json.decode(tools_only.content))
            test.not_nil(tools_document.mcpServers)
            test.is_nil(tools_document.hooks)
            local hooks_only = assert(settings({}, {"Stop"}))
            local hooks_document = assert(json.decode(hooks_only.content))
            test.is_nil(hooks_document.mcpServers)
            test.is_nil(hooks_document.secret_fields)
            test.not_nil(hooks_document.hooks.Stop)
        end)
        test.it("rejects gateway hooks Muse cannot deliver and unbound hook commands", function()
            local _, event_error = configuration.settings_file(gateway({"thread_read"}, {"SessionEnd2"}), HOOK_SOURCE)
            test.eq(event_error, "muse does not support gateway hook event SessionEnd2")
            local unbound = gateway({}, {"SessionStart"})
            unbound.hook_command = nil
            local _, command_error = configuration.settings_file(unbound, HOOK_SOURCE)
            test.eq(command_error, "muse hooks require the host-selected hook command")
            local uncredited = gateway({}, {"SessionStart"})
            uncredited.hook_token_environment = nil
            local _, token_error = configuration.settings_file(uncredited, HOOK_SOURCE)
            test.eq(token_error, "muse hooks require a separate hook credential environment")
            local _, source_error = configuration.settings_file(gateway({}, {"SessionStart"}))
            test.eq(source_error, "muse hooks require an attempt credential file")
        end)
        test.it("materializes one attempt-qualified private hook credential file", function()
            local first, first_source = configuration.hook_token_file("/private/muse", "attempt:first", "BEE_HOOK_TOKEN")
            local second, second_source = configuration.hook_token_file("/private/muse", "attempt:second", "BEE_HOOK_TOKEN")
            if not first or not first_source or not second or not second_source then error("hook token file was not rendered") end
            test.neq(first.path, second.path)
            test.neq(first_source, second_source)
            test.eq(first.content, '{"token":""}\n')
            test.eq(first.secret_fields and #first.secret_fields, 1)
            test.eq(first.secret_fields and first.secret_fields[1].environment, "BEE_HOOK_TOKEN")
            local rendered, render_error = placement_configuration.render(first, {BEE_HOOK_TOKEN = "private-hook-token"},
                {endpoint = "127.0.0.1:4312", tools = {}, hooks = {"Stop"}, destination = "BEE_GATEWAY_TOKEN", hook_destination = "BEE_HOOK_TOKEN"})
            if not rendered then error(tostring(render_error)) end
            test.eq((assert(json.decode(rendered))).token, "private-hook-token")
            test.is_nil(first.content:find("private-hook-token", 1, true))
        end)
        test.it("delivers the settings file and refuses providers and instructions", function()
            local reply = configure.handle({fixture = false,
                home_directory = "/private/muse", attempt_id = "attempt:one",
                gateway = {endpoint = "127.0.0.1:4312", action_id = "action-1", tools = {"thread_read"},
                    hooks = {"SessionStart"}, token_environment = "BEE_GATEWAY_TOKEN",
                    hook_token_environment = "BEE_HOOK_TOKEN", hook_command = "/abs/bee-hook"}})
            test.is_true(reply.ok)
            local delivery = reply.delivery :: {[string]: unknown}
            local files = delivery.files :: {{[string]: unknown}}
            test.eq(#files, 2)
            test.is_true(files[1].path:find(".config/muse/.bee-hooks/", 1, true) == 1)
            test.eq(files[2].path, ".config/muse/settings.json")
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
