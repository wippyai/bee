-- MIT. Driver method configure for grok: rejects provider configuration
-- and gateway hooks, delivering .grok/config.toml for gateway MCP.
local configuration = require("configuration")
local configure_protocol = require("configure_protocol")

local function handle(value: unknown): {[string]: unknown}
    local request, request_error = configure_protocol.decode_request(value)
    if not request then return {ok = false, error = request_error or "invalid configuration request"} end

    if request.provider_ref ~= nil or request.provider ~= nil then
        return {ok = false, error = "grok accepts no provider configuration"}
    end

    if request.gateway and #request.gateway.hooks > 0 then
        return {ok = false, error = "grok accepts no gateway hooks"}
    end

    local files = {}
    if request.gateway then
        local projected, projection_error = configuration.projection(request.gateway)
        if not projected then return {ok = false, error = tostring(projection_error)} end
        files[#files + 1] = {
            revision = projected.revision,
            path = projected.path,
            content = projected.content,
            digest = projected.digest,
            provider_ref = projected.provider_ref,
        }
    end

    local arguments: {string} = {}
    if request.instructions then arguments = {"--rules", request.instructions} end
    return {ok = true, delivery = {arguments = arguments, files = files}}
end

return {handle = handle}
