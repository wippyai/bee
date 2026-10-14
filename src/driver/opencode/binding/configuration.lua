-- SPDX-License-Identifier: MIT
local hash = require("hash")
local canonical = require("canonical")
local configure_protocol = require("configure_protocol")
local M = {}
M.REVISION = "bee.opencode-config@1"
M.PATH = ".config/opencode/opencode.json"
M.BASE_PATH = ".config/opencode/.bee-global-opencode.json"
M.SCHEMA = "https://opencode.ai/config.json"
M.MAX_CONFIGURATION_BYTES = 8192
type Gateway = configure_protocol.GatewayInput
type Configuration = configure_protocol.Configuration
function M.settings_file(gateway: Gateway): (Configuration?, string?)
    if #gateway.tools == 0 then return nil, "opencode configuration needs a gateway" end
    local document: {[string]: unknown} = {
        ["$schema"] = M.SCHEMA,
        mcp = {
            bee = {
                type = "remote",
                url = "http://" .. gateway.endpoint .. "/mcp/" .. gateway.action_id,
                enabled = true,
                headers = {Authorization = ""},
            },
        },
    }
    local content, content_error = canonical.encode(document)
    if not content then return nil, content_error end
    content = content .. "\n"
    if #content > M.MAX_CONFIGURATION_BYTES then return nil, "configuration exceeds " .. tostring(M.MAX_CONFIGURATION_BYTES) .. " bytes" end
    local digest, digest_error = hash.sha256(content)
    if not digest then return nil, tostring(digest_error or "configuration digest failed") end
    local operations: {configure_protocol.JsonOperation} = {
        {kind = "default", path = {"$schema"}},
        {kind = "insert", path = {"mcp", "bee"}},
    }
    local file: Configuration = {revision = M.REVISION, path = M.PATH, content = content, digest = digest,
        provider_ref = configure_protocol.GATEWAY_PROVIDER_REF,
        composition = {kind = "json_patch", base_path = M.BASE_PATH, operations = operations},
        secret_fields = {{path = {"mcp", "bee", "headers", "Authorization"}, environment = gateway.token_environment, prefix = "Bearer "}}}
    return file, nil
end
function M.login_configuration(): (configure_protocol.Configuration?, string?)
    local digest, digest_error = hash.sha256("")
    if not digest then return nil, tostring(digest_error or "configuration digest failed") end
    return {revision = M.REVISION, path = M.PATH, content = "", digest = digest,
        provider_ref = configure_protocol.LOGIN_PROVIDER_REF, composition = {kind = "copy", base_path = M.BASE_PATH}}, nil
end
return M
