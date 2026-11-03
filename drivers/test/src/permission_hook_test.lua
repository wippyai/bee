-- MIT. A permission hook waits for a person: each driver keeps its
-- PermissionRequest hook open for the shared permission hook window, which
-- outlives a host's ten-minute answer so its expiry answer reaches the agent.
local test = require("test")
local bounds = require("bounds")
local json = require("json")
local hook_limits = require("hook_limits")
local host_methods = require("host_methods")
local claude = host_methods.configure("claude")
local codex = require("codex")
local agy = host_methods.configure("agy")
local muse = require("muse")
local delivery = require("delivery")
local GATEWAY = {endpoint = "127.0.0.1:4312", action_id = "action-1", tools = {}, hooks = {"PermissionRequest"},
    token_environment = "BEE_GATEWAY_TOKEN", hook_token_environment = "BEE_HOOK_TOKEN", hook_command = "/abs/bee"}
local function delivered(reply: {[string]: unknown}): {[string]: unknown}
    if reply.ok ~= true then error(tostring(reply.error)) end
    return assert(bounds.object(reply.delivery))
end
local function permission_handler(document: {[string]: unknown}): {[string]: unknown}
    local hooks = assert(bounds.object(document.hooks))
    local group = assert(bounds.object(assert(bounds.array(hooks.PermissionRequest or hooks.PreToolUse, 4))[1]))
    return assert(bounds.object(assert(bounds.array(group.hooks, 4))[1]))
end
local function file_named(files: unknown, suffix: string): {[string]: unknown}
    for _, raw in ipairs(assert(bounds.array(files, 16))) do
        local file = assert(bounds.object(raw))
        local path = tostring(file.path)
        if path:sub(-#suffix) == suffix then return file end
    end
    error("no file " .. suffix)
end
local function define_tests()
    test.describe("Permission hook window", function()
        test.it("outlives a host's ten-minute permission answer", function()
            test.is_true(hook_limits.PERMISSION_SECONDS > 600)
        end)
        test.it("keeps every driver's PermissionRequest hook open for the permission window", function()
            local claude_arguments = assert(bounds.array(delivered(claude.handle({fixture = false, gateway = GATEWAY})).arguments, 16))
            local settings = assert(bounds.object(json.decode(tostring(claude_arguments[#claude_arguments]))))
            test.eq(permission_handler(settings).timeout, hook_limits.PERMISSION_SECONDS)
            local codex_arguments = assert(codex.session_arguments(GATEWAY))
            local rendered: string? = nil
            for _, argument in ipairs(codex_arguments) do
                if argument:sub(1, #"hooks.PermissionRequest=") == "hooks.PermissionRequest=" then rendered = argument end
            end
            test.ok(assert(rendered):find("timeout=" .. tostring(hook_limits.PERMISSION_SECONDS) .. ",", 1, true) ~= nil)
            local agy_file = file_named(delivered(agy.handle({fixture = false, home_directory = "/private/agy", gateway = GATEWAY})).files, "hooks.json")
            local agy_hooks = assert(bounds.object(assert(bounds.object(json.decode(tostring(agy_file.content)))).bee))
            test.eq(permission_handler({hooks = agy_hooks}).timeout, hook_limits.PERMISSION_SECONDS)
            local muse_file = assert(muse.settings_file(GATEWAY, "@/private/muse/.config/muse/.bee-hooks/attempt.json"))
            test.eq(permission_handler(assert(bounds.object(json.decode(muse_file.content)))).timeout, hook_limits.PERMISSION_SECONDS)
            test.eq(delivery.timeout("PermissionRequest"), tostring(hook_limits.PERMISSION_SECONDS) .. "s")
        end)
    end)
end
return test.run_cases(define_tests)
