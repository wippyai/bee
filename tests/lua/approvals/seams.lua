-- SPDX-License-Identifier: MIT
local process = require("process")
local registry = require("registry")

local M: {[string]: (unknown?) -> unknown} = {}

M["bee.approvals.persist.dispatch.paused"] = function(): unknown
    return process.registry.lookup("bee.test.effect_dispatch", process.registry.LOCAL) ~= nil
end

M["bee.approvals.binding.clock"] = function(): unknown
    local entry, problem = registry.get("bee.tests.approvals:fixture_instant")
    if not entry then error("approvals fixture instant: " .. tostring(problem)) end
    local value: unknown = entry.data
    assert(type(value) == "table", "approvals fixture instant")
    if value.milliseconds == nil then return nil end
    assert(type(value.milliseconds) == "number" and math.tointeger(value.milliseconds), "approvals fixture instant")
    return math.floor(value.milliseconds) * 1000000
end

return M
