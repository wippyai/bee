-- SPDX-License-Identifier: MIT
-- Deliberate non-yielding work: cancellation must stop CPU work, not just waits.
local process = require("process")
local function run(target: string): integer
    local sent, send_error = process.send(target, "research.spin.started", {})
    if not sent then error(tostring(send_error)) end
    local count = 0
    while true do count = (count + 1) % 1000 end
    return count
end
return {run = run}
