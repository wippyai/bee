-- SPDX-License-Identifier: MIT
local registry = require("registry")
local system = require("system")
local bounds = require("bounds")
local M = {}
function M.wait(advance: () -> boolean): boolean
    local gates: {string} = {}
    for _, entry in ipairs(assert(registry.find({["meta.type"] = "bee.process.boot_gate"}))) do
        local data = assert(bounds.object(entry.data))
        local lifecycle = assert(bounds.object(data.lifecycle))
        assert(entry.kind == "process.service" and lifecycle.startup == "complete", "boot gate requires one-shot completion")
        gates[#gates + 1] = entry.id
    end
    while true do
        local complete = true
        for _, id in ipairs(gates) do
            local state = assert(system.supervisor.state(id))
            assert(state.status ~= "failed", "boot gate failed: " .. id)
            if state.status ~= "exited" then complete = false end
        end
        if complete then return true end
        if not advance() then return false end
    end
end
return M
