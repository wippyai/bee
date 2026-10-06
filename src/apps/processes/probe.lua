-- On-demand runtime samples. Missing source values remain unavailable.
local system = require("system")
local bounds = require("bounds")
local registry = require("registry")
local M = {}
M.MAX_HOSTS = 128
M.MAX_PROCESSES = 2048
M.MAX_SERVICES = 1024

type Process = {pid: string, source: string, host: string, state: string, steps: integer?}
type Service = {id: string, state: string, desired: string, restarts: integer?, title: string?, detail: string?}
type Snapshot = {
    processes: {Process}, services: {Service}, heap: integer?, heap_objects: integer?, reserved: integer?,
    gc_cycles: integer?, goroutines: integer?, queue: integer?, executed: integer?,
    host_executed: {[string]: integer}, error: string,
}
type Sources = {
    hosts: () -> (unknown, unknown?),
    processes: (string) -> (unknown, unknown?),
    services: () -> (unknown, unknown?),
    -- titles names a service by its registry title, when it has one.
    titles: ((string) -> string?)?,
    memory: () -> (unknown, unknown?),
    goroutines: () -> (unknown, unknown?),
}
type Object = {[string]: unknown}

local function display_text(value: unknown, limit: integer, allow_empty: boolean): string?
    if type(value) ~= "string" or #value > limit or value:find("%c") or (not allow_empty and value == "") then return nil end
    return value
end

local function counter(value: unknown): integer?
    return bounds.count(value)
end

local function add_error(errors: {string}, value: unknown)
    if value ~= nil and tostring(value) ~= "" then errors[#errors + 1] = tostring(value) end
end

local function process_record(raw: unknown, default_host: string): (Process?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "malformed process record" end
    local pid = bounds.id(value.pid)
    local source = display_text(value.source, 512, true)
    local host = default_host
    if value.host ~= nil and value.host ~= "" then host = display_text(value.host, 160, false) end
    local state = display_text(value.state, 80, false)
    local steps: integer? = nil
    if value.steps ~= nil then steps = counter(value.steps) end
    if not pid or not source or type(host) ~= "string" or not state then return nil, "malformed process identity" end
    local problem: string? = nil
    if value.steps == nil or not steps then problem = "process steps counter unavailable for " .. pid end
    return {pid = pid, source = source, host = host, state = state, steps = steps}, problem
end

local function service_record(raw: unknown): (Service?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "malformed service record" end
    local id = bounds.id(value.id)
    local state = display_text(value.status, 80, false)
    local desired = display_text(value.desired, 80, false)
    local restarts: integer? = nil
    if value.retry_count ~= nil then restarts = counter(value.retry_count) end
    if not id or not state or not desired then return nil, "malformed service identity" end
    local problem: string? = nil
    if value.retry_count == nil or not restarts then problem = "service restart counter unavailable for " .. id end
    -- Any reported detail means the service stopped with an error; its text
    -- is shown on one line.
    local detail: string? = nil
    if value.details ~= nil then detail = (tostring(value.details):gsub("%c", " ")):sub(1, 200) end
    return {id = id, state = state, desired = desired, restarts = restarts, detail = detail}, problem
end

local function aggregate_hosts(snapshot: Snapshot, errors: {string}, sources: Sources)
    local raw_hosts, hosts_error = sources.hosts()
    if hosts_error then add_error(errors, "hosts.list: " .. tostring(hosts_error)); return end
    local hosts = bounds.array(raw_hosts, M.MAX_HOSTS)
    if not hosts then add_error(errors, "hosts.list: malformed or oversized host snapshot"); return end

    local queue_total, executed_total = 0, 0
    local queue_complete, executed_complete = true, true
    local seen: {[string]: boolean} = {}
    for _, raw_host in ipairs(hosts) do
        local host = bounds.object(raw_host)
        local id = host and bounds.id(host.id)
        if not host or not id or seen[id] then
            add_error(errors, "hosts.list: malformed or duplicate host identity")
            queue_complete, executed_complete = false, false
        else
            seen[id] = true
            local queue = counter(host.queue_depth)
            if queue == nil then
                queue_complete = false
                add_error(errors, "hosts.list: queue counter unavailable for " .. id)
            else queue_total = queue_total + queue end
            local executed = counter(host.executed)
            if executed == nil then
                executed_complete = false
                add_error(errors, "hosts.list: executed counter unavailable for " .. id)
            else
                executed_total = executed_total + executed
                snapshot.host_executed[id] = executed
            end

            local raw_processes, processes_error = sources.processes(id)
            if processes_error then add_error(errors, "hosts.processes(" .. id .. "): " .. tostring(processes_error))
            else
                local rows = bounds.array(raw_processes, M.MAX_PROCESSES)
                if not rows then add_error(errors, "hosts.processes(" .. id .. "): malformed or oversized process snapshot")
                else
                    for _, raw_process in ipairs(rows) do
                        if #snapshot.processes >= M.MAX_PROCESSES then
                            add_error(errors, "hosts.processes: process snapshot exceeds " .. tostring(M.MAX_PROCESSES) .. " rows")
                            break
                        end
                        local process, problem = process_record(raw_process, id)
                        if process then snapshot.processes[#snapshot.processes + 1] = process end
                        add_error(errors, problem)
                    end
                end
            end
        end
    end
    if queue_complete then snapshot.queue = queue_total end
    if executed_complete then snapshot.executed = executed_total end
end

local function aggregate_services(snapshot: Snapshot, errors: {string}, sources: Sources)
    local raw_services, source_error = sources.services()
    if source_error then add_error(errors, "supervisor.states: " .. tostring(source_error)); return end
    local rows = bounds.array(raw_services, M.MAX_SERVICES)
    if not rows then add_error(errors, "supervisor.states: malformed or oversized service snapshot"); return end
    for _, raw in ipairs(rows) do
        if #snapshot.services >= M.MAX_SERVICES then
            add_error(errors, "supervisor.states: service snapshot exceeds " .. tostring(M.MAX_SERVICES) .. " rows")
            break
        end
        local service, problem = service_record(raw)
        if service then
            if sources.titles then service.title = sources.titles(service.id) end
            snapshot.services[#snapshot.services + 1] = service
        end
        add_error(errors, problem)
    end
end

local function aggregate_memory(snapshot: Snapshot, errors: {string}, sources: Sources)
    local raw, source_error = sources.memory()
    if source_error then add_error(errors, "memory.stats: " .. tostring(source_error)); return end
    local memory = bounds.object(raw)
    if not memory then add_error(errors, "memory.stats: malformed statistics"); return end
    snapshot.heap = counter(memory.heap_alloc)
    snapshot.heap_objects = counter(memory.heap_objects)
    snapshot.reserved = counter(memory.sys)
    snapshot.gc_cycles = counter(memory.num_gc)
    if snapshot.heap == nil then add_error(errors, "memory.stats: heap unavailable") end
    if snapshot.heap_objects == nil then add_error(errors, "memory.stats: heap objects unavailable") end
    if snapshot.reserved == nil then add_error(errors, "memory.stats: reserved memory unavailable") end
    if snapshot.gc_cycles == nil then add_error(errors, "memory.stats: GC cycles unavailable") end
end

function M.sample_with(sources: Sources): Snapshot
    local errors: {string} = {}
    local snapshot: Snapshot = {processes = {}, services = {}, host_executed = {}, error = ""}
    aggregate_hosts(snapshot, errors, sources)
    aggregate_services(snapshot, errors, sources)
    aggregate_memory(snapshot, errors, sources)

    local goroutines, goroutines_error = sources.goroutines()
    if goroutines_error then add_error(errors, "runtime.goroutines: " .. tostring(goroutines_error))
    else
        snapshot.goroutines = counter(goroutines)
        if snapshot.goroutines == nil then add_error(errors, "runtime.goroutines: value unavailable") end
    end
    if #errors > 0 then snapshot.error = table.concat(errors, "; ") end
    return snapshot
end

function M.sample(): Snapshot
    return M.sample_with({
        hosts = function(): (unknown, unknown?) return system.hosts.list() end,
        processes = function(host_id: string): (unknown, unknown?) return system.hosts.processes(host_id) end,
        services = function(): (unknown, unknown?) return system.supervisor.states() end,
        titles = function(id: string): string?
            local entry = registry.get(id)
            local meta = entry and bounds.object(entry.meta)
            return meta and display_text(meta.title, 80, false) or nil
        end,
        memory = function(): (unknown, unknown?) return system.memory.stats() end,
        goroutines = function(): (unknown, unknown?) return system.runtime.goroutines() end,
    })
end


return M
