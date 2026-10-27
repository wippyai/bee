-- SPDX-License-Identifier: MIT
-- The existing endpoint provider template projects the built-in Anthropic
-- provider override into Pi's models.json. Keys stay in the environment.
local configure_protocol = require("configure_protocol")
local shared = require("shared")
local universal = require("universal")
local bounds = require("bounds")
local canonical = require("canonical")
local hash = require("hash")
local function handle(request: configure_protocol.Request): {[string]: unknown}
    if request.gateway and (#request.gateway.tools > 0 or #request.gateway.hooks > 0) then
        return {ok = false, error = "pi has no gateway adapter"}
    end
    if not request.provider_ref and not request.provider then
        return {ok = true, delivery = {arguments = {}, files = {}}}
    end
    local options = request.option_values or {}
    if options.provider ~= nil and options.provider ~= "anthropic" then
        return {ok = false, error = "Pi Anthropic endpoints require provider anthropic"}
    end
    local model = options.model
    if type(model) == "string" and model:find("/", 1, true) and not model:match("^anthropic/") then
        return {ok = false, error = "Pi Anthropic endpoints require an Anthropic model"}
    end
    local entry = bounds.object(request.provider)
    local meta = entry and bounds.object(entry.meta)
    local data = entry and bounds.object(entry.data)
    if not request.provider_ref or not meta or meta.type ~= "bee.pi_provider" or not data
        or bounds.fields(data, {"base_url", "plain_http"}) then
        return {ok = false, error = "pi configuration needs the selected endpoint provider"}
    end
    if data.plain_http ~= nil and type(data.plain_http) ~= "boolean" then
        return {ok = false, error = "pi plain_http must be a boolean"}
    end
    local url, err = shared.endpoint(data.base_url, false, "base_url", data.plain_http == true)
    if not url then return {ok = false, error = tostring(err)} end
    local content, encode_error = canonical.encode({providers = {anthropic = {baseUrl = url}}})
    if not content then return {ok = false, error = tostring(encode_error)} end
    local digest = hash.sha256(content)
    if not digest then return {ok = false, error = "pi configuration digest unavailable"} end
    return {ok = true, delivery = {arguments = {"--provider", "anthropic"}, files = {{
        revision = "bee.pi-config@1", path = ".pi/agent/models.json", content = content,
        digest = digest, provider_ref = request.provider_ref,
    }}}}
end
return {handle = universal.configure("pi", {pi = handle}, "bee.drivers.pi.descriptor:cli")}
