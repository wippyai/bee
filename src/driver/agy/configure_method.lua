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
            return {ok = false, error = "agy does not support gateway HTTP hooks"}
        end
        local mcp_file, mcp_error = configuration.mcp_file(request.gateway)
        if not mcp_file then return {ok = false, error = tostring(mcp_error)} end
        files[1] = mcp_file
    end
    return {ok = true, delivery = {arguments = {}, files = files}}
end

return {handle = handle}
