-- SPDX-License-Identifier: MIT
local measure_clock = require("measure_clock")
local M: {[string]: (unknown?) -> unknown} = {}
M["bee.harness.launch.measure"] = function(): unknown
    return measure_clock.instant
end
return M
