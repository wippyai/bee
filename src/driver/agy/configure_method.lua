-- MIT. Pure Antigravity CLI driver configuration method.
local configuration = require("configuration")
local configure_protocol = require("configure_protocol")

local function handle(value: unknown): {[string]: unknown}
    local request, request_error = configure_protocol.decode_request(value)
    if not request then return {ok = false, error = request_error or "invalid configuration request"} end
    if request.provider_ref ~= nil or request.provider ~= nil then
        return {ok = false, error = "agy accepts no provider configuration"}
    end
    local files = {}
    if request.gateway ~= nil then
        if #request.gateway.hooks > 0 then
            local hook_file, hook_error = configuration.hooks_file(request.gateway)
            if not hook_file then return {ok = false, error = tostring(hook_error)} end
            files[#files + 1] = hook_file
        end
        if #request.gateway.tools > 0 then
            local mcp_file, mcp_error = configuration.mcp_file(request.gateway)
            if not mcp_file then return {ok = false, error = tostring(mcp_error)} end
            files[#files + 1] = mcp_file
        end
    end
    if request.instructions then
        local file, file_error = configuration.instructions_file(request.instructions)
        if not file then return {ok = false, error = tostring(file_error)} end
        files[#files + 1] = file
    end
    local arguments = {}
    if #files > 0 then
        if not request.home_directory then
            return {ok = false, error = "agy additive configuration needs the owner-derived home_directory"}
        end
        -- Agy has no alternate config-home variable. Its supported --add-dir
        -- makes this retained, session-owned directory an additional
        -- customization root while HOME continues to name the user's ordinary
        -- global configuration and credentials.
        arguments = {"--add-dir", request.home_directory}
    end
    return {ok = true, delivery = {arguments = arguments, files = files}}
end

return {handle = handle}
