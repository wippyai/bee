-- SPDX-License-Identifier: MIT
local process = require("process")
local M = {}
M.SWEEP_INTERVAL_MS = 10
function M.pending(): boolean
    return process.registry.lookup("bee.test.docker.attempt") ~= nil
end
function M.sweep(): {ok: boolean}
    local controller = process.registry.lookup("bee.test.docker.revoked")
    if controller and M.pending() then assert(process.send(tostring(controller), "bee.test.docker.stopped", {})) end
    return {ok = true}
end
return M
