-- MIT. A fixture-selected instant for gateway expiry checks.
local time = require("time")
local registry = require("registry")
local sql = require("sql")
local M = {}
function M.now(): time.Time
    local entry = assert(registry.get("bee.gateway:fixture_instant"))
    local value: unknown = entry.data
    assert(type(value) == "table", "gateway fixture instant")
    if value.at == nil then return time.now() end
    assert(type(value.at) == "string", "gateway fixture instant")
    return assert(time.parse("2006-01-02T15:04:05.000Z07:00", value.at))
end
function M.wall_nanoseconds(): integer
    local db = assert(sql.get("bee:db"))
    local rows = assert(db:query("SELECT offset_ms FROM bee_test_hook_clock WHERE id=1"))
    db:release()
    local offset = rows[1].offset_ms
    assert(type(offset) == "number")
    return time.now():unix_nano() + math.floor(offset * 1000000)
end
return M
