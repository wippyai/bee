-- SPDX-License-Identifier: MIT
--
-- Read-only process and runtime sampler.  This module deliberately has no
-- background producer: callers decide when a sample is needed, so opening the
-- Process Manager is the only thing that enables host/process inspection.

local system = require("system")
local viz = require("viz")

local M = {}

M.HISTORY_LIMIT = 60

type Process = {
    pid: string,
    source: string,
    host: string,
    state: string,
    steps: number,
}
type Service = {
    id: string,
    state: string,
    desired: string,
    restarts: number,
}
type Snapshot = {
    processes: {Process},
    services: {Service},
    heap: number?,
    heap_objects: number?,
    reserved: number?,
    gc_cycles: number?,
    goroutines: number?,
    queue: number?,
    executed: number?,
    host_executed: {[string]: number},
    error: string,
}
type History = {
    heap: viz.Series,
    rate: viz.Series,
    queue: viz.Series,
}

local function text(value: unknown): string
    if value == nil then return "" end
    return tostring(value)
end

local function nonnegative(value: unknown): number?
    local result = tonumber(value)
    if result == nil or result ~= result or result == math.huge or result == -math.huge or result < 0 then return nil end
    return result
end

local function add_error(errors: {string}, value: unknown)
    local message = text(value)
    if message ~= "" then errors[#errors + 1] = message end
end

-- sample obtains each source independently.  A failed source is represented by
-- an omitted metric and one combined error string; values from healthy sources
-- remain useful to the caller.
function M.sample(): Snapshot
    local errors: {string} = {}
    local snapshot: Snapshot = {processes = {}, services = {}, host_executed = {}, error = ""}

    local raw_hosts, hosts_error = system.hosts.list()
    if hosts_error then
        add_error(errors, "hosts.list: " .. text(hosts_error))
    else
        local queue_total = 0
        local executed_total = 0
        local queue_complete = true
        local executed_complete = true

        for _, host in ipairs(raw_hosts or {}) do
            local queue = nonnegative(host.queue_depth)
            if queue == nil then queue_complete = false else queue_total = queue_total + queue end
            local executed = nonnegative(host.executed)
            if executed == nil then
                executed_complete = false
            else
                executed_total = executed_total + executed
                snapshot.host_executed[text(host.id)] = executed
            end

            local raw_processes, processes_error = system.hosts.processes(host.id)
            if processes_error then
                add_error(errors, "hosts.processes(" .. text(host.id) .. "): " .. text(processes_error))
            else
                for _, record in ipairs(raw_processes or {}) do
                    local steps = nonnegative(record.steps)
                    snapshot.processes[#snapshot.processes + 1] = {
                        pid = text(record.pid),
                        source = text(record.source),
                        host = text(record.host) ~= "" and text(record.host) or text(host.id),
                        state = text(record.state),
                        steps = steps or 0,
                    }
                end
            end
        end

        if queue_complete then snapshot.queue = queue_total end
        if executed_complete then snapshot.executed = executed_total end
    end

    local raw_services, services_error = system.supervisor.states()
    if services_error then
        add_error(errors, "supervisor.states: " .. text(services_error))
    else
        for _, service in ipairs(raw_services or {}) do
            local restarts = nonnegative(service.retry_count)
            snapshot.services[#snapshot.services + 1] = {
                id = text(service.id),
                state = text(service.status),
                desired = text(service.desired),
                restarts = restarts or 0,
            }
        end
    end

    local memory, memory_error = system.memory.stats()
    if memory_error then
        add_error(errors, "memory.stats: " .. text(memory_error))
    else
        snapshot.heap = nonnegative(memory.heap_alloc)
        if snapshot.heap == nil then add_error(errors, "memory.stats: heap unavailable") end
        snapshot.heap_objects = nonnegative(memory.heap_objects)
        snapshot.reserved = nonnegative(memory.sys)
        snapshot.gc_cycles = nonnegative(memory.num_gc)
        if snapshot.heap_objects == nil then add_error(errors, "memory.stats: heap objects unavailable") end
        if snapshot.reserved == nil then add_error(errors, "memory.stats: reserved memory unavailable") end
        if snapshot.gc_cycles == nil then add_error(errors, "memory.stats: GC cycles unavailable") end
    end

    local goroutines, goroutines_error = system.runtime.goroutines()
    if goroutines_error then
        add_error(errors, "runtime.goroutines: " .. text(goroutines_error))
    else
        snapshot.goroutines = nonnegative(goroutines)
        if snapshot.goroutines == nil then add_error(errors, "runtime.goroutines: value unavailable") end
    end

    if #errors > 0 then snapshot.error = table.concat(errors, "; ") end
    return snapshot
end

function M.new_history(): History
    return {heap = viz.series(M.HISTORY_LIMIT), rate = viz.series(M.HISTORY_LIMIT), queue = viz.series(M.HISTORY_LIMIT)}
end

-- append records a bounded time series.  viz.GAP is intentionally a visible
-- gap rather than zero: unavailable data must never look like an idle
-- scheduler or an empty heap.  elapsed is measured in seconds.
function M.append(history: History, snapshot: Snapshot, previous: Snapshot?, elapsed: number): History
    local heap = nonnegative(snapshot.heap)
    viz.push(history.heap, heap or viz.GAP)

    local queue = nonnegative(snapshot.queue)
    viz.push(history.queue, queue or viz.GAP)

    local rate: number? = nil
    local seconds = nonnegative(elapsed) or 0
    if previous ~= nil and seconds > 0 and nonnegative(snapshot.executed) ~= nil
        and nonnegative(previous.executed) ~= nil then
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
                local current_value: number = current_hosts[host_id]
                local prior_value: number? = prior_hosts[host_id]
                if prior_value == nil or current_value < prior_value then
                    same_hosts = false
                    break
                end
                delta = delta + current_value - prior_value
            end
            if same_hosts then rate = delta / seconds end
        end
    end
    viz.push(history.rate, rate or viz.GAP)
    return history
end

return M
