-- SPDX-License-Identifier: MIT
-- Waits for a condition on database state by waking on the node's change
-- stream, never by polling.
local cdc = require("cdc")
local channel = require("channel")
local time = require("time")

local M = {}

-- until_changed re-checks the predicate whenever one of the tables changes,
-- or whenever source delivers, until it holds; the timeout only bounds a
-- failure. The stream opens before the first check and is drained before
-- each re-check, so a change landing meanwhile wakes the next wait.
function M.until_changed(tables: {string}, predicate: () -> boolean, timeout_ms: integer, source: channel.Channel<any>?): boolean
    local changes = assert(cdc.stream("bee:changes", {tables = tables, ops = {"insert", "update"}}))
    local updates = assert(changes:channel())
    local bound = time.after(tostring(timeout_ms) .. "ms")
    local holds = false
    while true do
        if predicate() then holds = true; break end
        local cases = {updates:case_receive(), bound:case_receive()}
        if source then cases[3] = source:case_receive() end
        local selected = channel.select(cases)
        if selected.channel == bound or not selected.ok then break end
        while true do
            local queued = channel.select({updates:case_receive(), default = true})
            if queued.default or not queued.ok then break end
        end
    end
    changes:close()
    return holds
end

return M
