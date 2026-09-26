-- MIT. The pure OpenCode configuration contract: the carrier and placement
-- select both this method and its gateway from their pinned host records.
-- OpenCode takes no provider entry: models stay user-configured, so a
-- request naming one is refused rather than rendered.
local configuration = require("configuration")
local configure_protocol = require("configure_protocol")
local function handle(value: unknown): {[string]: unknown}
    local request, request_error = configure_protocol.decode_request(value)
    if not request then return {ok = false, error = request_error or "invalid configuration request"} end
    if request.provider_ref or request.provider then
        return {ok = false, error = "opencode configures no model provider; the user selects models in their own OpenCode home"}
    end
    if request.instructions or request.instruction_builder then
        return {ok = false, error = "opencode accepts no profile instructions"}
    end
    if not request.gateway or #request.gateway.tools == 0 then
        if request.gateway then
            for _, event in ipairs(request.gateway.hooks) do
                return {ok = false, error = "opencode does not support gateway hook event " .. event}
            end
        end
        return {ok = true, delivery = {arguments = {}, files = {}}}
    end
    local file, file_error = configuration.settings_file(request.gateway)
    if not file then return {ok = false, error = tostring(file_error)} end
    return {ok = true, delivery = {arguments = {}, files = {file}}}
end
return {handle = handle}
