-- SPDX-License-Identifier: MIT
-- Read the endpoint selected by the host from the native listener's state.
-- A discovered port describes a destination; it grants no gateway authority.
local registry = require("registry")
local system = require("system")
local configuration = require("configuration")
local function handle(value: unknown): (configuration.Listener?, string?)
    if type(value) ~= "table" or next(value) ~= nil then return nil, "gateway address request must be empty" end
    local configured, config_error = configuration.configured()
    if not configured then return nil, config_error end
    local selected: configuration.Listener = {address = configured}
    if not configured:match(":0$") then return selected, nil end
    local entry, entry_error = registry.get("bee.gateway:listener_ref")
    if entry_error or not entry then return nil, "gateway listener is not linked" end
    local data = entry.data
    if type(data) ~= "table" then return nil, "gateway listener is not linked" end
    local reference = (data :: {[string]: unknown}).resource_ref
    if type(reference) ~= "string" or reference == "" then return nil, "gateway listener is not linked" end
    local state, state_error = system.supervisor.state(reference)
    if state_error or not state or state.id ~= reference then return nil, "gateway listener state is unavailable" end
    if state.status ~= "running" then return nil, "gateway listener is " .. state.status end
    local details = state.details
    if not details then return nil, "gateway listener has not reported its address" end
    local address = details:match("^service listening on ([%d%.]+:%d+)$")
    if not address or not configuration.valid_address(address, false) then
        return nil, "gateway listener has not reported a valid address"
    end
    if address:match("^([^:]+):") ~= configured:match("^([^:]+):") then return nil, "gateway listener differs from the host-selected interface" end
    if state.started_at <= 0 or state.retry_count < 0 then return nil, "gateway listener has no execution identity" end
    return {address = address, native_key = reference .. ":" .. tostring(state.started_at) .. ":" .. tostring(state.retry_count) .. ":" .. address}, nil
end
return {handle = handle}
