-- SPDX-License-Identifier: MIT
local registry = require("registry")
local time = require("time")

type Advance = (integer) -> ()

local function with_clock(body: (Advance) -> ())
    local instant = assert(registry.get("bee.tests.approvals:fixture_instant"))
    local original = instant.data
    local milliseconds = math.floor(time.now():unix_nano() / 1000000)
    local function advance(duration: integer)
        milliseconds = milliseconds + duration
        instant.data = {milliseconds = milliseconds}
        local changes = registry.snapshot():changes()
        changes:update(instant)
        assert(changes:apply())
    end
    advance(0)
    local ok, problem = pcall(body, advance)
    instant.data = original
    local changes = registry.snapshot():changes()
    changes:update(instant)
    assert(changes:apply())
    if not ok then error(tostring(problem)) end
end

return {with_clock = with_clock}
