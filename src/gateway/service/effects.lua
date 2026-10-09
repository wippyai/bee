-- SPDX-License-Identifier: MIT
local registry = require("registry")
local security = require("security")
local funcs = require("funcs")
local bounds = require("bounds")
local M = {}
local function executor(kind: string): (funcs.Executor, string, string)
    local consumers = registry.find({["meta.type"] = "bee.approvals.effect-consumer", ["meta.worker_name"] = "bee.gateway.external"}) or {}
    for _, entry in ipairs(registry.find({["meta.type"] = "bee.gateway.effect_scope"}) or {}) do
        local data = bounds.object(entry.data)
        if data and data.kind == kind and type(data.entry) == "string" then
            local destination: string? = nil
            for _, consumer in ipairs(consumers) do
                local meta = bounds.object(consumer.meta)
                if consumer.id == data.entry and meta then destination = bounds.id(meta.destination) end
            end
            if not destination then error("gateway effect consumer missing: " .. kind) end
            local policies: {security.Policy} = {}
            for _, id in ipairs(assert(bounds.array(data.policies, 64))) do
                if type(id) ~= "string" then error("invalid gateway effect scope") end
                policies[#policies + 1] = assert(security.policy(id))
            end
            local scoped = funcs.new():with_actor(security.new_actor("bee.gateway.worker"))
                :with_scope(security.new_scope(policies))
            return assert(scoped), data.entry, destination
        end
    end
    error("gateway effect scope missing: " .. kind)
end
local function pending_kind(destination: string, scoped: funcs.Executor): boolean
    local raw, problem = scoped:call("bee.approvals.binding:effect_queue", {destination = destination, limit = 1})
    local reply = bounds.object(raw)
    local value = reply and reply.ok == true and bounds.object(reply.value)
    local effects = value and bounds.array(value.effects, 64)
    if not effects or problem then error(problem or "gateway effect queue unreadable") end
    return #effects > 0
end
function M.pending(): boolean
    for _, kind in ipairs({"installation", "publication"}) do
        local scoped, _, destination = executor(kind)
        if pending_kind(destination, scoped) then return true end
    end
    return false
end
function M.drain(kind: string): boolean
    local scoped, entry, destination = executor(kind)
    while true do
        local raw, problem = scoped:call(entry)
        local reply = bounds.object(raw)
        if problem then error(problem) end
        if not reply or reply.ok ~= true then return false end
        if not pending_kind(destination, scoped) then return true end
        if type(reply.count) ~= "number" or reply.count < 1 then error("gateway effect queue makes no progress") end
    end
end
return M
