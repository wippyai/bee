-- MIT. The pure Codex configuration contract: the carrier and placement
-- select both this method and its provider from their pinned host records.
local configuration = require("configuration")
local configure_protocol = require("configure_protocol")
local function handle(value: unknown): {[string]: unknown}
    local request, request_error = configure_protocol.decode_request(value)
    if not request then return {ok = false, error = request_error or "invalid configuration request"} end
    if not request.provider_ref or not request.provider then return {ok = false, error = "codex configuration needs the selected provider"} end
    local provider, decode_error = configuration.decode(request.provider_ref, request.provider)
    if not provider then return {ok = false, error = tostring(decode_error)} end
    if provider.loopback_fixture and request.fixture ~= true then return {ok = false, error = "loopback fixture provider needs a fixture policy"} end
    local projected, projection_error = configuration.projection(provider, request.gateway_section)
    if not projected then return {ok = false, error = tostring(projection_error)} end
    return {ok = true, configuration = {revision = projected.revision, path = projected.path, content = projected.content, digest = projected.digest, provider_ref = projected.provider_ref}}
end
return {handle = handle}
