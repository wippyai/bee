-- SPDX-License-Identifier: MIT
local process = require("process")
local M = {}
M.TOPIC = "bee.process.demand"
M.WAKE = "bee.process.wake"
M.DISPATCH = "bee.process.dispatch"
M.SUPERVISOR = "bee.hive.supervisor"
local function signal(name: string, action: string, value: unknown): (boolean, string?)
    local pid, problem = process.registry.lookup(M.SUPERVISOR, process.registry.LOCAL)
    if not pid then return false, tostring(problem or "demand supervisor is unavailable") end
    local sent, send_error = process.send(tostring(pid), M.TOPIC, {name = name, action = action, value = value})
    return sent == true, send_error and tostring(send_error) or nil
end
function M.wake(name: string): (boolean, string?)
    return signal(name, "wake", nil)
end
function M.dispatch(name: string, value: unknown): (boolean, string?)
    return signal(name, "dispatch", value)
end
function M.ready(name: string): (boolean, string?)
    return signal(name, "ready", nil)
end
function M.quiet(name: string, generation: integer): (boolean, string?)
    return signal(name, "quiet", generation)
end
return M
