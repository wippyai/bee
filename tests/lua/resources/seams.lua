-- SPDX-License-Identifier: MIT
-- Resource callers and their background supervision read the instant a suite
-- pins in bee.tests.resources:fixture_instant.
local registry = require("registry")
local M: {[string]: (unknown?) -> unknown} = {}
M["bee.resources.persist.clock"] = function(): unknown
    local entry, problem = registry.get("bee.tests.resources:fixture_instant")
    if not entry then error("resource fixture instant: " .. tostring(problem)) end
    local value: unknown = entry.data
    assert(type(value) == "table", "resource fixture instant")
    if value.milliseconds == nil then return nil end
    assert(type(value.milliseconds) == "number" and math.tointeger(value.milliseconds), "resource fixture instant")
    return math.floor(value.milliseconds) * 1000000
end
return M
