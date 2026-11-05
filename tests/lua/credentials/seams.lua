-- SPDX-License-Identifier: MIT
-- Credential lease calls read the instant their function context selects.
local ctx = require("ctx")
local M: {[string]: (unknown?) -> unknown} = {}
M["bee.credentials.binding.clock"] = function(): unknown
    local instant = ctx.get("bee.test.credentials.milliseconds")
    if instant == nil then return nil end
    assert(type(instant) == "number" and math.tointeger(instant), "credential fixture instant")
    return math.floor(instant) * 1000000
end
return M
