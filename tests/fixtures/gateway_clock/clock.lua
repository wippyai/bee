-- MIT. A fixture-selected instant for gateway expiry checks.
local time = require("time")
local registry = require("registry")
local M = {}
function M.now(): time.Time
    local entry = assert(registry.get("bee.gateway:fixture_instant"))
    local value: unknown = entry.data
    assert(type(value) == "table", "gateway fixture instant")
    if value.at == nil then return time.now() end
    assert(type(value.at) == "string", "gateway fixture instant")
    return assert(time.parse("2006-01-02T15:04:05.000Z07:00", value.at))
end
return M
