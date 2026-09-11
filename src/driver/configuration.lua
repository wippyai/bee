-- MIT. The typed, declarative configure boundary shared by every driver
-- caller.  A driver receives copied registry data under an empty callee
-- scope and may return one measured file for the attempt's private home.
local hash = require("hash")
local bounds = require("bounds")
local funcs = require("funcs")
local security = require("security")
local M = {}
M.MAX_CONFIGURATION_BYTES = 8192
M.MAX_GATEWAY_SECTION_BYTES = 8192
type Configuration = {revision: string, path: string, content: string, digest: string, provider_ref: string}
type Request = {provider_ref: string?, provider: {[string]: unknown}?, gateway_section: string?, fixture: boolean}

function M.decode_request(value: unknown): (Request?, string?)
    local request = bounds.object(value)
    if not request then return nil, "configuration request must be an object" end
    local unknown = bounds.fields(request, {"provider_ref", "provider", "gateway_section", "fixture"})
    if unknown then return nil, "configuration request: " .. unknown end
    if type(request.fixture) ~= "boolean" then return nil, "configuration request.fixture must be a boolean" end
    local provider_ref: string? = nil
    local provider: {[string]: unknown}? = nil
    if request.provider_ref ~= nil then
        provider_ref = bounds.id(request.provider_ref)
        if not provider_ref then return nil, "configuration request.provider_ref is not an identifier" end
        provider = bounds.object(request.provider)
        if not provider then return nil, "configuration request.provider must be an object when provider_ref is set" end
    elseif request.provider ~= nil then
        return nil, "configuration request.provider needs provider_ref"
    end
    local gateway_section: string? = nil
    if request.gateway_section ~= nil then
        gateway_section = bounds.text(request.gateway_section, M.MAX_GATEWAY_SECTION_BYTES)
        if not gateway_section or gateway_section == "" then return nil, "configuration request.gateway_section must be nonempty bounded text" end
    end
    return {provider_ref = provider_ref, provider = provider, gateway_section = gateway_section, fixture = request.fixture :: boolean}, nil
end

function M.decode_file(value: unknown): (Configuration?, string?)
    local item = bounds.object(value)
    if not item then return nil, "configuration must be an object" end
    local unknown = bounds.fields(item, {"revision", "path", "content", "digest", "provider_ref"})
    if unknown then return nil, "configuration: " .. unknown end
    local revision = bounds.id(item.revision)
    if not revision then return nil, "configuration.revision is not an identifier" end
    local path, path_error = bounds.subpath(item.path)
    if path_error then return nil, "configuration.path " .. path_error end
    if not path or path == "" then return nil, "configuration.path must be a nonempty safe relative path" end
    local content = bounds.text(item.content, M.MAX_CONFIGURATION_BYTES)
    if not content or content == "" then return nil, "configuration.content must be bounded nonempty text" end
    local digest = bounds.id(item.digest)
    if not digest or #digest ~= 64 or not digest:match("^[0-9a-f]+$") then return nil, "configuration.digest must be a lowercase sha256 hex digest" end
    local actual, hash_error = hash.sha256(content)
    if hash_error or not actual then return nil, "configuration.digest could not be measured" end
    if digest ~= actual then return nil, "configuration.digest does not match content" end
    local provider_ref = bounds.id(item.provider_ref)
    if not provider_ref then return nil, "configuration.provider_ref is not an identifier" end
    return {revision = revision, path = path, content = content, digest = digest, provider_ref = provider_ref}, nil
end

function M.decode_reply(value: unknown, selected_provider: string?): (Configuration?, string?)
    local reply = bounds.object(value)
    if not reply then return nil, "driver configure: reply must be an object" end
    local unknown = bounds.fields(reply, {"ok", "error", "configuration"})
    if unknown then return nil, "driver configure: " .. unknown end
    if type(reply.ok) ~= "boolean" then return nil, "driver configure: ok must be a boolean" end
    if reply.ok == false then
        if reply.configuration ~= nil then return nil, "driver configure: refused reply carries configuration" end
        local error_text = bounds.text(reply.error, 1024)
        if not error_text or error_text == "" then return nil, "driver configure: refused reply needs an error" end
        return nil, "driver configure: " .. error_text
    end
    if reply.error ~= nil then return nil, "driver configure: successful reply carries error" end
    if reply.configuration == nil then
        if selected_provider then return nil, "driver configure omitted the selected provider configuration" end
        return nil, nil
    end
    if not selected_provider then return nil, "driver configure returned configuration without a selected provider" end
    local configuration, configuration_error = M.decode_file(reply.configuration)
    if not configuration then return nil, "driver configure: " .. tostring(configuration_error) end
    if configuration.provider_ref ~= selected_provider then return nil, "driver configure: configuration names an unselected provider" end
    return configuration, nil
end

-- The caller's context authorizes the trusted method before the empty scope
-- begins.  The callee receives no placement, registry, executor or nested
-- call authority; the request contains declarative copies only.
function M.call(target: string, request_value: unknown): (Configuration?, string?)
    local request, request_error = M.decode_request(request_value)
    if not request then return nil, request_error end
    local scoped, scope_error = funcs.new():with_scope(security.new_scope({}))
    if not scoped then return nil, "configuration scope: " .. tostring(scope_error) end
    local raw, call_error = scoped:call(target, request)
    if call_error then return nil, "driver configure: " .. tostring(call_error) end
    return M.decode_reply(raw, request.provider_ref)
end
return M
