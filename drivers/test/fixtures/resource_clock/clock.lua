-- MIT. One fixture instant shared by resource callers and their supervisors.
local time = require("time")
local registry = require("registry")
local M = {}
function M.milliseconds(): integer
    local entry = assert(registry.get("bee.resources:fixture_instant"))
    local value: unknown = entry.data
    assert(type(value) == "table", "resource fixture instant")
    if value.milliseconds == nil then return math.floor(time.now():unix_nano() / 1000000) end
    assert(type(value.milliseconds) == "number" and math.tointeger(value.milliseconds), "resource fixture instant")
    return math.floor(value.milliseconds)
end
return M
