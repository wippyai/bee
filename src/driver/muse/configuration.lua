-- MIT. The Muse settings file: the one file the private config home needs
-- for the admitted gateway. Muse offers no argv delivery for MCP servers,
-- hooks or instructions, so configure renders settings.json under the
-- private XDG_CONFIG_HOME. Hook handlers are commands: the host-selected
-- hook executable receives each event as JSON on stdin. Token bytes never
-- enter the content; placement injects them through secret_fields.
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local quote = require("quote")
local configure_protocol = require("configure_protocol")
local M = {}
M.REVISION = "bee.muse-config@1"
M.PATH = "muse/settings.json"
M.MAX_CONFIGURATION_BYTES = 8192
M.HOOK_TIMEOUT = 3
-- Every event here is accepted by muse 1.3.0 at startup; anything else is
-- refused rather than rendered into a skipped handler group.
M.HOOK_EVENTS = {"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "SessionEnd"}
type Gateway = configure_protocol.GatewayInput
type Configuration = configure_protocol.Configuration
function M.settings_file(gateway: Gateway): (Configuration?, string?)
    local selected: {[string]: unknown} = {}
    for _, event in ipairs(gateway.hooks) do
        local supported = false
        for _, name in ipairs(M.HOOK_EVENTS) do
            if event == name then supported = true end
        end
        if not supported then return nil, "muse does not support gateway hook event " .. event end
    end
    local executable = gateway.hook_command
    if #gateway.hooks > 0 and not executable then return nil, "muse hooks require the host-selected hook command" end
    local hook_token = gateway.hook_token_environment
    if #gateway.hooks > 0 and not hook_token then return nil, "muse hooks require a separate hook credential environment" end
    for _, event in ipairs(gateway.hooks) do
        local command = quote.line({executable :: string, "hook-post", gateway.endpoint, gateway.action_id, hook_token :: string, event})
        selected[event] = {{hooks = {{type = "command", command = command, timeout = M.HOOK_TIMEOUT}}}}
    end
    local document: {[string]: unknown} = {schema_version = 1}
    if #gateway.tools > 0 then
        document.mcpServers = {bee = {url = "http://" .. gateway.endpoint .. "/mcp/" .. gateway.action_id, headers = {Authorization = ""}}}
    end
    if #gateway.hooks > 0 then document.hooks = selected end
    local content, content_error = canonical.encode(document)
    if not content then return nil, content_error end
    content = content .. "\n"
    if #content > M.MAX_CONFIGURATION_BYTES then return nil, "configuration exceeds " .. tostring(M.MAX_CONFIGURATION_BYTES) .. " bytes" end
    local digest, digest_error = hash.sha256(content)
    if not digest then return nil, tostring(digest_error or "configuration digest failed") end
    local file: Configuration = {revision = M.REVISION, path = M.PATH, content = content, digest = digest, provider_ref = configure_protocol.GATEWAY_PROVIDER_REF}
    if #gateway.tools > 0 then
        file.secret_fields = {{path = {"mcpServers", "bee", "headers", "Authorization"}, environment = gateway.token_environment, prefix = "Bearer "}}
    end
    return file, nil
end
return M
