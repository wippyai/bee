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
        local hook_token_source: string? = nil
        if #request.gateway.hooks > 0 then
            if not request.home_directory or not request.attempt_id then
                return {ok = false, error = "muse hooks need the owner-derived home_directory and attempt_id"}
            end
            local token_file: configure_protocol.Configuration?
            local token_error: string?
            token_file, hook_token_source, token_error = configuration.hook_token_file(request.home_directory, request.attempt_id,
                request.gateway.hook_token_environment :: string)
            if not token_file then return {ok = false, error = tostring(token_error)} end
            files[#files + 1] = token_file
        end
        local settings, settings_error = configuration.settings_file(request.gateway, hook_token_source)
        if not settings then return {ok = false, error = tostring(settings_error)} end
        files[#files + 1] = settings
    end
    return {ok = true, delivery = {arguments = {}, files = files}}
end
return {handle = handle}
