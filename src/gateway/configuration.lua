-- MIT. Host-selected gateway address and credential destinations.
-- Driver components render their own native harness configuration.
local registry = require("registry")
local funcs = require("funcs")
local M = {}
M.DESTINATION = "BEE_GATEWAY_TOKEN"
M.HOOK_DESTINATION = "BEE_GATEWAY_HOOK_TOKEN"
M.SERVER = "bee"
M.ENDPOINT = "bee:gateway_endpoint"
type Object = {[string]: unknown}
type Listener = {address: string, native_key: string?}
function M.valid_address(value: unknown, allow_zero: boolean): boolean
    if type(value) ~= "string" then return false end
    local port_text = (value :: string):match("^127%.0%.0%.1:(%d+)$")
    if not port_text then return false end
    local port = tonumber(port_text)
    return port ~= nil and port >= (allow_zero and 0 or 1) and port <= 65535 and tostring(port) == port_text
end
function M.configured(): (string?, string?)
    local entry, err = registry.get(M.ENDPOINT)
    if err or not entry then return nil, "gateway endpoint is not configured by the host" end
    local data = entry.data
    if type(data) ~= "table" then return nil, "gateway endpoint has no data" end
    local address = (data :: Object).address
    if not M.valid_address(address, true) then return nil, "gateway endpoint must be a loopback host and port" end
    return address :: string, nil
end
function M.current(): (Listener?, string?)
    local value, err = funcs.call("bee.gateway:address", {})
    if err then return nil, tostring(err) end
    if type(value) ~= "table" then return nil, "gateway listener address is unavailable" end
    local data = value :: Object
    if not M.valid_address(data.address, false) then return nil, "gateway listener address is invalid" end
    local key = data.native_key
    if key ~= nil and (type(key) ~= "string" or #key == 0 or #key > 512) then return nil, "gateway listener execution is invalid" end
    return {address = data.address :: string, native_key = key :: string?}, nil
end
function M.endpoint(): (string?, string?)
    local listener, err = M.current()
    if not listener then return nil, err end
    return listener.address, nil
end
function M.url(address: string, action_id: string): string
    return "http://" .. address .. "/mcp/" .. action_id
end
return M
