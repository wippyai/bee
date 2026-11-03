-- SPDX-License-Identifier: MIT
local funcs = require("funcs")
local bounds = require("bounds")
local admission = require("admission")
local M = {}
local function page(target: string, request: {[string]: unknown}): {[string]: unknown}
    local raw, problem = funcs.call(target, request)
    local reply = bounds.object(raw)
    assert(not problem and reply and reply.ok == true, "configuration effect backlog unreadable: " .. tostring(problem))
    return assert(bounds.object(reply.value))
end
function M.pending(): boolean
    local owner = admission.DESTINATION
    local effects = assert(bounds.array(page("bee.approvals.binding:effect_queue", {destination = owner, limit = 1}).effects, 64))
    if #effects > 0 then return true end
    local cursor = 0
    while true do
        local result = page("bee.approvals.binding:events", {destination = owner, cursor = cursor, limit = 64})
        local events = assert(bounds.array(result.events, 64))
        for _, raw in ipairs(events) do
            if assert(bounds.object(raw)).acknowledged_at == nil then return true end
        end
        if #events < 64 then return false end
        cursor = assert(bounds.count(result.cursor))
    end
end
return M
