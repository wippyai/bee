-- SPDX-License-Identifier: MIT
local controllers = require("controllers")
local ctx = require("ctx")
local registry = require("registry")
-- The Sessions SDK suites' synthetic owners answer the session contracts
-- unless a suite hands the contract back to the node's owner by marking the
-- synthetic binding default = false.
local OWNERS: {[string]: string} = {
    ["bee.threads.sessions:contract"] = "bee.tests.threads.sessions:fake_owner",
    ["bee.threads.sessions:catalog"] = "bee.tests.threads.sessions:fake_catalog_owner",
}
local function answering(contract: string): string?
    local owner = OWNERS[contract]
    if not owner then return nil end
    local entry, problem = registry.get(owner)
    if not entry then error("synthetic sessions owner " .. owner .. ": " .. tostring(problem)) end
    local data = entry.data :: {contracts: {{contract: string, default: boolean?}}}
    for _, implemented in ipairs(data.contracts) do
        if implemented.contract == contract then return implemented.default ~= false and owner or nil end
    end
    return nil
end
return {
    ["bee.contract.binding"] = function(payload: unknown?): unknown
        if type(payload) ~= "table" or type(payload.contract) ~= "string" then return nil end
        return answering(payload.contract)
    end,
    ["bee.threads.service.owners"] = function()
        if ctx.get("bee.test.registry.fault") == "bee.threads.owner" then return "registry unavailable" end
        return nil
    end,
    ["bee.threads.hooks.cancelled"] = function(pending)
        local hook = pending :: {id: string, future: {is_canceled: (any) -> boolean}}
        controllers.notify("bee.test.hook.cancelled", nil, {invocation_id = hook.id, cancelled = hook.future:is_canceled()})
        return nil
    end,
    ["bee.threads.hooks.budget"] = function(payload)
        return controllers.registered("bee.test.hook.budget", "bee.test.hook.expire", nil, payload)
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
