-- MIT. Typed Antigravity CLI (agy) configuration delivery under an empty callee scope.
-- Agy accepts no host provider configuration. Gateway tools are rendered as
-- safe-relative configuration files. Command hooks use the host-selected Bee
-- executable and report observations without emitting permission decisions.
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local quote = require("quote")
local configure_protocol = require("configure_protocol")

local M = {}

M.REVISION = "bee.agy-config@1"
M.MCP_REVISION = "bee.agy-mcp@2"
M.CUSTOMIZATION_DIRECTORY = ".agents"
M.MCP_PATH = M.CUSTOMIZATION_DIRECTORY .. "/mcp_config.json"

M.AGY_AUTHENTICATION = "unproven"
M.AGY_HOOKS = "unproven"
M.AGY_MCP = "unproven"

function M.render_mcp(gateway: configure_protocol.GatewayInput): string
    local url = "http://" .. gateway.endpoint .. "/mcp/" .. gateway.action_id
    local doc = {
        mcpServers = {
            bee = {
                serverUrl = url,
                headers = {
                    Authorization = "",
                },
            },
        },
    }
    local encoded, err = canonical.encode(doc)
    if not encoded then error("render mcp: " .. tostring(err)) end
    return encoded .. "\n"
end

function M.mcp_file(gateway: configure_protocol.GatewayInput): (configure_protocol.Configuration?, string?)
    local content = M.render_mcp(gateway)
    local digest, hash_error = hash.sha256(content)
    if hash_error or not digest then return nil, "mcp digest failed" end
    return {
        revision = M.MCP_REVISION,
        secret_fields = {{path = {"mcpServers", "bee", "headers", "Authorization"}, environment = gateway.token_environment, prefix = "Bearer "}},
        path = M.MCP_PATH,
        content = content,
        digest = digest,
        provider_ref = configure_protocol.GATEWAY_PROVIDER_REF,
    }, nil
end

-- Agy discovers persistent rules from an added customization root, separately
-- from the conversation's user messages. Do not create or change project files.
function M.instructions_file(text: string): (configure_protocol.Configuration?, string?)
    local content, content_error = configure_protocol.instructions(text)
    if not content then return nil, content_error or "instructions are missing" end
    local digest, digest_error = hash.sha256(content)
    if not digest then return nil, tostring(digest_error or "instructions digest failed") end
    return {revision = "bee.agy-instructions@2", path = M.CUSTOMIZATION_DIRECTORY .. "/AGENTS.md", content = content,
        digest = digest, provider_ref = configure_protocol.INSTRUCTIONS_PROVIDER_REF}, nil
end
-- Agy uses matcher groups for tool events and flat entries for Stop.
function M.hooks_file(gateway: configure_protocol.GatewayInput): (configure_protocol.Configuration?, string?)
    local executable = gateway.hook_command
    if not executable then return nil, "agy hooks require the host-selected hook command" end
    local hook_token = gateway.hook_token_environment
    if not hook_token then return nil, "agy hooks require a separate hook credential environment" end
    local selected: {[string]: unknown} = {}
    for _, event in ipairs(gateway.hooks) do
        if event ~= "PreToolUse" and event ~= "PostToolUse" and event ~= "Stop" then
            return nil, "agy does not support gateway hook event " .. event
        end
        local command = quote.line({executable, "hook-post", gateway.endpoint, gateway.action_id, hook_token, event})
        local handler = {type = "command", command = command, timeout = 3}
        if event == "Stop" then
            selected[event] = {handler}
        else
            selected[event] = {{matcher = "", hooks = {handler}}}
        end
    end
    local content, content_error = canonical.encode({bee = selected})
    if not content then return nil, content_error end
    content = content .. "\n"
    local digest, digest_error = hash.sha256(content)
    if not digest then return nil, "hook configuration digest failed" end
    return {revision = "bee.agy-hooks@2", path = M.CUSTOMIZATION_DIRECTORY .. "/hooks.json", content = content,
        digest = digest, provider_ref = configure_protocol.GATEWAY_PROVIDER_REF}, nil
end
return M
