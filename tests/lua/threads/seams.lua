-- SPDX-License-Identifier: MIT
local controllers = require("controllers")
local events = require("events")
local ctx = require("ctx")
-- The Sessions SDK suites' synthetic owners answer the session contracts.
local OWNERS: {[string]: string} = {
    ["bee.threads.sessions:contract"] = "bee.tests.threads.sessions:fake_owner",
    ["bee.threads.sessions:catalog"] = "bee.tests.threads.sessions:fake_catalog_owner",
}
return {
    ["bee.contract.binding"] = function(payload: unknown?): unknown
        if type(payload) ~= "table" or type(payload.contract) ~= "string" then return nil end
        return OWNERS[payload.contract]
    end,
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
    ["bee.threads.service.pump"] = function()
        return false
    end,
}
