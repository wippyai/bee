-- SPDX-License-Identifier: MIT
local gateway_hooks = require("gateway_hooks")
local events = require("events")
local M = {}
function M.run(_: unknown): {[string]: unknown}
    local subscription, err = events.subscribe(gateway_hooks.signal("01a1ab5e-aac8-7c52-b867-6fb8b0e8035a"), gateway_hooks.QUEUED)
    if not subscription then return {error = tostring(err)} end
    subscription:close()
    return {subscribed = true}
end
return M
