-- SPDX-License-Identifier: MIT
local process = require("process")

local M: {[string]: (unknown?) -> unknown} = {}

M["bee.approvals.persist.dispatch.paused"] = function(): unknown
    return process.registry.lookup("bee.test.effect_dispatch", process.registry.LOCAL) ~= nil
end

return M
