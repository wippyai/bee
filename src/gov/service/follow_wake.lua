-- MIT. Wakes the node's serialized activation worker.
local process = require("process")
local M = {}
function M.signal()
    local pid = process.registry.lookup("bee.gov.activation_worker")
    if pid then process.send(tostring(pid), "bee.approvals.wake", {version = 1}) end
end
return M
