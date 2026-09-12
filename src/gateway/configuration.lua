-- MIT. Host-selected gateway address and credential destinations.
-- Driver components render their own native harness configuration.
local registry = require("registry")
local M = {}
M.DESTINATION = "BEE_GATEWAY_TOKEN"
M.HOOK_DESTINATION = "BEE_GATEWAY_HOOK_TOKEN"
M.SERVER = "bee"
M.ENDPOINT = "bee:gateway_endpoint"
type Object = {[string]: unknown}
function M.endpoint(): (string?, string?)
    local entry, err = registry.get(M.ENDPOINT)
    if err or not entry then return nil, "gateway endpoint is not configured by the host" end
    local data = entry.data
    if type(data) ~= "table" then return nil, "gateway endpoint has no data" end
    local address = (data :: Object).address
    if type(address) ~= "string" or not (address :: string):find("^127%.0%.0%.1:%d+$") then return nil, "gateway endpoint must be a loopback host and port" end
    return address :: string, nil
end
function M.url(address: string, action_id: string): string
    return "http://" .. address .. "/mcp/" .. action_id
end
return M
