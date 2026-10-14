-- SPDX-License-Identifier: MIT
local demand = require("demand")
local M = {}
function M.signal()
    assert(demand.wake("bee.gov.activation_worker"))
end
return M
