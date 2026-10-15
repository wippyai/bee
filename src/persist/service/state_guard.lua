-- SPDX-License-Identifier: MIT
local process = require("process")
local guard = require("guard")
local M = {}
function M.main()
    local problem = guard.inspect()
    if problem then
        local reporter, report_error = process.spawn("bee.persist:state_refusal", "bee:terminal", problem)
        assert(reporter, tostring(report_error))
        error("Bee state version is incompatible")
    end
end
return M
