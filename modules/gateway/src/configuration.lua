-- MIT. Host-selected gateway address and credential destinations.
-- Driver components render their own native harness configuration.
local registry = require("registry")
local funcs = require("funcs")
local env = require("env")
local address_value = require("address_value")
local M = {}
M.DESTINATION = "BEE_GATEWAY_TOKEN"
M.HOOK_DESTINATION = "BEE_GATEWAY_HOOK_TOKEN"
M.SERVER = "bee"
M.ENDPOINT = "bee.gateway:endpoint_ref"
type Object = {[string]: unknown}
type Listener = {address: string, native_key: string?}
M.valid_address = address_value.valid
-- Host headers must name this exact listener, including its selected port.
-- localhost is an alias only for the default loopback address.
M.host_matches = address_value.host_matches
function M.configured(): (string?, string?)
    local reference, reference_error = registry.get(M.ENDPOINT)
    if reference_error or not reference then return nil, "gateway endpoint is not linked by the host" end
    local linked = reference.data
    if type(linked) ~= "table" then return nil, "gateway endpoint is not linked by the host" end
    local endpoint = (linked :: Object).resource_ref
    if type(endpoint) ~= "string" or endpoint == "" then return nil, "gateway endpoint is not linked by the host" end
    local entry, err = registry.get(endpoint :: string)
    if err or not entry then return nil, "gateway endpoint is not configured by the host" end
    local data = entry.data
    if type(data) ~= "table" then return nil, "gateway endpoint has no data" end
    local address = (data :: Object).address
    if not M.valid_address(address, true) then return nil, "gateway endpoint must be a loopback or private IPv4 host and port" end
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
-- The host names the executable variable; drivers receive only its resolved
-- absolute path. No command is discovered from a harness payload.
function M.hook_command(reference: string?): (string?, string?)
    if reference == nil then return nil, nil end
    local value, err = env.get(reference)
    if not value or #value == 0 or #value > 4096 or value:sub(1, 1) ~= "/" or value:find("%c") then
        return nil, "hook command is unavailable from the host-selected variable"
    end
    return value, nil
end
function M.url(address: string, action_id: string): string
    return "http://" .. address .. "/mcp/" .. action_id
end
return M
