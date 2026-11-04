-- SPDX-License-Identifier: MIT
local controllers = require("controllers")
local events = require("events")
local ctx = require("ctx")
return {
    ["bee.threads.service.owners"] = function()
        if ctx.get("bee.test.registry.fault") == "bee.threads.owner" then return "registry unavailable" end
        return nil
    end,
    ["bee.threads.hooks.cancelled"] = function(pending)
        local hook = pending :: {id: string, future: {is_canceled: (any) -> boolean}}
        events.send("bee.test.hook/" .. hook.id, "cancelled", hook.id, {cancelled = hook.future:is_canceled()})
        return nil
    end,
    ["bee.threads.service.committed"] = function()
        return controllers.registered("bee.test.threads.hold", "bee.test.threads.release", nil, {})
    end,
    ["bee.threads.service.capture_closed"] = function()
        return controllers.registered("bee.test.threads.terminal", "bee.test.threads.resume", nil, {})
    end,
}
