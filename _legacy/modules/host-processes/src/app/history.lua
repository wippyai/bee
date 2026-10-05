-- SPDX-License-Identifier: MIT
local viz = require("viz")
local probe = require("probe")
local M = {}
M.HISTORY_LIMIT = 60
type History = {heap: viz.Series, rate: viz.Series, queue: viz.Series}
function M.new_history(): History
    return {heap = viz.series(M.HISTORY_LIMIT), rate = viz.series(M.HISTORY_LIMIT), queue = viz.series(M.HISTORY_LIMIT)}
end

-- Missing metrics become visible gaps; rates resume only across complete matching host sets.
function M.append(history: History, snapshot: probe.Snapshot, previous: probe.Snapshot?, elapsed: number): History
    viz.push(history.heap, snapshot.heap or viz.GAP)
    viz.push(history.queue, snapshot.queue or viz.GAP)

    local rate: number? = nil
    local seconds = elapsed == elapsed and elapsed > 0 and elapsed < math.huge and elapsed or 0
    if previous ~= nil and seconds > 0 and snapshot.executed ~= nil and previous.executed ~= nil then
        local current_hosts = snapshot.host_executed
        local prior_hosts = previous.host_executed
        local same_hosts = true
        local current_count, prior_count = 0, 0
        for host_id in pairs(current_hosts) do
            current_count = current_count + 1
            if prior_hosts[host_id] == nil then same_hosts = false end
        end
        for host_id in pairs(prior_hosts) do
            prior_count = prior_count + 1
            if current_hosts[host_id] == nil then same_hosts = false end
        end
        if same_hosts and current_count == prior_count then
            local delta = 0
            for host_id in pairs(current_hosts) do
                local current_value = current_hosts[host_id]
                local prior_value = prior_hosts[host_id]
                if current_value < prior_value then same_hosts = false; break end
                delta = delta + current_value - prior_value
            end
            if same_hosts then rate = delta / seconds end
        end
    end
    viz.push(history.rate, rate or viz.GAP)
    return history
end

return M
