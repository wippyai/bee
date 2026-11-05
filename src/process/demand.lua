-- SPDX-License-Identifier: MIT
-- Signals to the node's Hive supervisor about demand-driven services. The
-- supervisor adopts every registered owner and probes every owner's durable
-- backlog when it starts, so a signal it cannot take while it is absent is
-- served by that startup recovery; the signal reports the outcome and logs it.
local process = require("process")
local logger = require("logger")
local M = {}
M.TOPIC = "bee.process.demand"
M.WAKE = "bee.process.wake"
M.ACCEPTED = "bee.process.accepted"
M.SUPERVISOR = "bee.hive.supervisor"
local function signal(name: string, action: string, value: unknown): (boolean, string?)
    local pid, problem = process.registry.lookup(M.SUPERVISOR, process.registry.LOCAL)
    local sent, send_error = false, tostring(problem or "demand supervisor is unavailable")
    if pid then
        local delivered, delivery_error = process.send(tostring(pid), M.TOPIC, {name = name, action = action, value = value})
        sent, send_error = delivered == true, delivery_error and tostring(delivery_error) or nil
    end
    if not sent then
        logger:warn("Hive demand signal left to the supervisor's startup recovery", {name = name, action = action, cause = send_error})
    end
    return sent, send_error
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
