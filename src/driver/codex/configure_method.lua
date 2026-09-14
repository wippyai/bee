-- MIT. The pure Codex configuration contract: the carrier and placement
-- select both this method and its provider from their pinned host records.
local configuration = require("configuration")
local configure_protocol = require("configure_protocol")
local function handle(value: unknown): {[string]: unknown}
    local request, request_error = configure_protocol.decode_request(value)
    if not request then return {ok = false, error = request_error or "invalid configuration request"} end
    if not request.provider_ref and not request.provider then
        local arguments, argument_error = configuration.session_arguments(request.gateway, request.instructions)
        if not arguments then return {ok = false, error = tostring(argument_error)} end
        return {ok = true, delivery = {arguments = arguments, files = {}}}
    end
    if not request.provider_ref or not request.provider then return {ok = false, error = "codex configuration needs the selected provider"} end
    local provider, decode_error = configuration.decode(request.provider_ref, request.provider)
    if not provider then return {ok = false, error = tostring(decode_error)} end
    if provider.loopback_fixture and request.fixture ~= true then return {ok = false, error = "loopback fixture provider needs a fixture policy"} end
    if request.instructions then
        if provider.developer_instructions then return {ok = false, error = "instructions are declared in both the launch policy and provider"} end
    end
    local section: string? = nil
    if request.gateway then section = configuration.gateway_section(request.gateway) end
    local projected, projection_error = configuration.projection(provider, section, request.instructions)
    if not projected then return {ok = false, error = tostring(projection_error)} end
    local files = {{revision = projected.revision, path = projected.path, content = projected.content, digest = projected.digest, provider_ref = projected.provider_ref}}
    if request.gateway and #request.gateway.hooks > 0 then
        if not request.home_directory then return {ok = false, error = "codex hooks need the owner-derived home_directory"} end
        local hooks, hooks_error = configuration.hook_files(request.gateway, request.home_directory)
        if not hooks then return {ok = false, error = tostring(hooks_error)} end
        for _, file in ipairs(hooks) do files[#files + 1] = {revision = file.revision, path = file.path, content = file.content, digest = file.digest, provider_ref = file.provider_ref} end
    end
    local arguments: {string} = {}
    if request.gateway and #request.gateway.hooks > 0 then arguments = {"--profile", "bee"} end
    return {ok = true, delivery = {arguments = arguments, files = files}}
end
return {handle = handle}
