-- MIT. Muse on Bee: the shipped routes bind Bee's hook executable, and Bee's
-- placement composes the driver's settings and hook credential files.
local test = require("test")
local bounds = require("bounds")
local json = require("json")
local registry = require("registry")
local configuration = require("configuration")
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
    test.describe("Muse configuration on Bee", function()
        test.it("binds the command hook executable on both shipped routes", function()
            for _, ref in ipairs({"bee.driver.muse.security:launch_policy_muse_window", "bee.driver.muse.security:launch_policy_muse_batch"}) do
                local entry, entry_error = registry.get(ref)
                if not entry then error(tostring(entry_error or (ref .. " is missing"))) end
                local data = assert(bounds.object(entry.data))
                test.eq(data.hook_command_ref, "bee.gateway.env:hook_executable")
            end
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
        test.it("materializes the attempt hook credential file with the hook token", function()
            local first = configuration.hook_token_file("/private/muse", "attempt:first", "BEE_HOOK_TOKEN")
            if not first then error("hook token file was not rendered") end
            local rendered, render_error = placement_configuration.render(first, {BEE_HOOK_TOKEN = "private-hook-token"},
                {endpoint = "127.0.0.1:4312", tools = {}, hooks = {"Stop"}, destination = "BEE_GATEWAY_TOKEN", hook_destination = "BEE_HOOK_TOKEN"})
            if not rendered then error(tostring(render_error)) end
            test.eq((assert(json.decode(rendered))).token, "private-hook-token")
            test.is_nil((first.content:find("private-hook-token", 1, true)))
        end)
    end)
end
return test.run_cases(define_tests)
