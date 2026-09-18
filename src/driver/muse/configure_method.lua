-- MIT. The pure Muse configuration contract: the carrier and placement
-- select both this method and its gateway from their pinned host records.
-- Muse accepts no provider configuration; the user's `muse login` owns
-- authentication, the same boundary as the Codex chatgpt login mode.
local configuration = require("configuration")
local configure_protocol = require("configure_protocol")
local function handle(value: unknown): {[string]: unknown}
    local request, request_error = configure_protocol.decode_request(value)
    if not request then return {ok = false, error = request_error or "invalid configuration request"} end
    if request.provider_ref ~= nil or request.provider ~= nil then
        return {ok = false, error = "muse accepts no provider configuration"}
    end
    if request.instructions then return {ok = false, error = "muse accepts no profile instructions"} end
    local files = {}
    if request.gateway and (#request.gateway.tools > 0 or #request.gateway.hooks > 0) then
        local settings, settings_error = configuration.settings_file(request.gateway)
        if not settings then return {ok = false, error = tostring(settings_error)} end
        files[#files + 1] = settings
    end
    return {ok = true, delivery = {arguments = {}, files = files}}
end
return {handle = handle}
