-- SPDX-License-Identifier: MIT
local demand = require("demand")
local M = {}
function M.signal()
    demand.wake("bee.gov.activation_worker")
end
return M
