-- MIT. Typed Antigravity CLI (agy) configuration delivery under an empty callee scope.
-- Agy accepts no host provider configuration. Gateway tools are rendered as
-- safe-relative .gemini/config/mcp_config.json files. Unproven gateway HTTP hooks
-- are accurately rejected.
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local configure_protocol = require("configure_protocol")

local M = {}

M.REVISION = "bee.agy-config@1"
M.MCP_REVISION = "bee.agy-mcp@1"
M.MCP_PATH = ".gemini/config/mcp_config.json"

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
                    Authorization = "Bearer ${" .. gateway.token_environment .. "}",
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
        path = M.MCP_PATH,
        content = content,
        digest = digest,
        provider_ref = configure_protocol.GATEWAY_PROVIDER_REF,
    }, nil
end

-- Agy reads global persistent rules from its private HOME, separately from
-- the conversation's user messages. Do not create or change project files.
function M.instructions_file(text: string): (configure_protocol.Configuration?, string?)
    local content, content_error = configure_protocol.instructions(text)
    if not content then return nil, content_error or "instructions are missing" end
    local digest, digest_error = hash.sha256(content)
    if not digest then return nil, tostring(digest_error or "instructions digest failed") end
    return {revision = "bee.agy-instructions@1", path = ".gemini/GEMINI.md", content = content,
        digest = digest, provider_ref = configure_protocol.INSTRUCTIONS_PROVIDER_REF}, nil
end
return M
