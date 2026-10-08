-- SPDX-License-Identifier: MIT
local json = require("json")
local bounds = require("bounds")
local address = require("address")
local M = {}
function M.render(name: string, endpoint: string, action: string, token: string): (string?, string?)
    if not address.valid(endpoint, false) or not endpoint:match("^127%.") then return nil, "external MCP requires a loopback listener" end
    if not bounds.id(action) or action:find("[^%w_:%-%.]") then return nil, "invalid gateway action" end
    if #token == 0 or #token > 128 or token:find("[^%w+/=_%-%.]") then return nil, "invalid gateway token" end
    local url = "http://" .. endpoint .. "/mcp/" .. action
    local encoded, err = json.encode({mcpServers = {bee = {type = "http", url = url, headers = {Authorization = "Bearer ${BEE_MCP_TOKEN}"}}}})
    if not encoded then return nil, tostring(err) end
    return name .. " is connected. Save the token now; Bee shows it once.\n"
        .. "export BEE_MCP_TOKEN='" .. token .. "'\n\n.mcp.json:\n```json\n" .. encoded .. "\n```\n\n"
        .. 'claude mcp add --transport http bee ' .. url .. ' --header "Authorization: Bearer $BEE_MCP_TOKEN"\n\n'
        .. 'Codex config.toml:\n```toml\n[mcp_servers.bee]\nurl = "' .. url .. '"\nbearer_token_env_var = "BEE_MCP_TOKEN"\n```', nil
end
return M
