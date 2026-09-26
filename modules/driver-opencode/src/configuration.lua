-- MIT. The OpenCode configuration file: the one file the inherited home
-- needs for the admitted gateway. OpenCode reads MCP servers only from its
-- JSON configuration, so configure renders opencode.json with the single
-- scoped bee remote entry and composes it into the user's own configuration
-- without replacing unrelated keys. Token bytes never enter the content;
-- placement injects them through secret_fields before OpenCode reads the
-- file. Models, providers and permissions stay
-- user-configured; this component renders no provider entry. OpenCode has no
-- hook transport, so any requested hook event is refused.
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
    for _, event in ipairs(gateway.hooks) do
        return nil, "opencode does not support gateway hook event " .. event
    end
    if #gateway.tools == 0 then return nil, "opencode configuration needs at least one gateway tool" end
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
    local operations: {{kind: "default" | "insert" | "append", path: {string}}} = {
        {kind = "default", path = {"$schema"}},
        {kind = "insert", path = {"mcp", "bee"}},
    }
    local file: Configuration = {revision = M.REVISION, path = M.PATH, content = content, digest = digest,
        provider_ref = configure_protocol.GATEWAY_PROVIDER_REF,
        composition = {kind = "json_patch", base_path = M.BASE_PATH, operations = operations},
        secret_fields = {{path = {"mcp", "bee", "headers", "Authorization"}, environment = gateway.token_environment, prefix = "Bearer "}}}
    return file, nil
end
return M
