-- Pure dashboard over measured runtime samples, composed from the application
-- frame and the visualization kit: stat tiles, then a grid of panels whose
-- count follows the size class (2x2 compact, 3x2 standard, 4x2 wide). No
-- calls, polling or mutable ownership.
local appearance = require("appearance")
local frame = require("frame")
local viz = require("viz")
local probe = require("probe")
local text = require("text")

type Frame = {rows: {string}, hits: {frame.Hit}}
type Count = {name: string, count: integer}
type Panel = (painter: frame.Painter, cell: frame.Rect) -> ()
local M = {}
local MIB = 1048576
local HINTS = frame.hints({{key = "Enter", verb = "refresh"}, {key = "P", verb = "pause"}, {key = "Esc", verb = "close"}})
local GRID: {[string]: {integer}} = {compact = {2, 2}, standard = {3, 2}, wide = {4, 2}}

-- Occurrences of each value, most frequent first, then by name.
local function tally(values: {string}): {Count}
    local counts: {[string]: integer} = {}
    local order: {string} = {}
    for _, value in ipairs(values) do
        local name = value ~= "" and value or "unknown"
        if not counts[name] then order[#order + 1] = name end
        counts[name] = (counts[name] or 0) + 1
    end
    local result: {Count} = {}
    for _, name in ipairs(order) do result[#result + 1] = {name = name, count = counts[name] or 0} end
    table.sort(result, function(a: Count, b: Count): boolean
        if a.count ~= b.count then return a.count > b.count end
        return a.name < b.name
    end)
    return result
end

local function scaled(series: viz.Series, divisor: number): {number}
    local values: {number} = {}
    for index, value in ipairs(viz.values(series)) do values[index] = value / divisor end
    return values
end

local function service_role(state: string): string
    if state == "running" or state == "started" then return "ok" end
    if state == "failed" or state == "error" then return "error" end
    if state == "starting" or state == "restarting" or state == "retrying" or state == "stopping" then return "warn" end
    return "muted"
end

local function plural(count: integer, one: string, many: string): string
    return viz.count(count) .. " " .. (count == 1 and one or many)
end

local function heap_panel(snapshot: probe.Snapshot, history: probe.History): Panel
    return function(painter: frame.Painter, cell: frame.Rect)
        local inner = frame.panel(painter, cell, "Heap", snapshot.heap and viz.bytes(snapshot.heap) or "")
        if not snapshot.heap then frame.empty(painter, inner.y, "Heap unavailable", "R retry", inner); return end
        viz.line(painter, inner, {{values = scaled(history.heap, MIB)}}, {area = true, unit = "MiB", from = "-60s", to = "now"})
    end
end

local function scheduler_panel(history: probe.History): Panel
    return function(painter: frame.Painter, cell: frame.Rect)
        local latest = viz.latest(history.rate)
        local inner = frame.panel(painter, cell, "Scheduler", latest and viz.number(latest, "steps/s") or "")
        viz.line(painter, inner, {{values = viz.values(history.rate)}}, {from = "-60s", to = "now"})
    end
end

local function states_panel(snapshot: probe.Snapshot): Panel
    return function(painter: frame.Painter, cell: frame.Rect)
        local inner = frame.panel(painter, cell, "Processes by state", plural(#snapshot.processes, "process", "processes"))
        local states: {string} = {}
        for index, item in ipairs(snapshot.processes) do states[index] = text.bound(item.state, 64) end
        local bars: {viz.Bar} = {}
        for index, item in ipairs(tally(states)) do bars[index] = {label = item.name, value = item.count} end
        if #bars == 0 then frame.empty(painter, inner.y, "No processes reported", "R retry", inner); return end
        viz.bars(painter, inner, bars)
    end
end

local function services_panel(snapshot: probe.Snapshot): Panel
    return function(painter: frame.Painter, cell: frame.Rect)
        local inner = frame.panel(painter, cell, "Services", plural(#snapshot.services, "service", "services"))
        if #snapshot.services == 0 then frame.empty(painter, inner.y, "No services reported", "R retry", inner); return end
        local states: {string} = {}
        local roles: {string} = {}
        for index, item in ipairs(snapshot.services) do
            states[index] = text.bound(item.state, 64)
            roles[index] = service_role(item.state)
        end
        local words: {string} = {}
        for _, item in ipairs(tally(states)) do words[#words + 1] = viz.count(item.count) .. " " .. item.name end
        frame.put(painter, inner.x, inner.y, table.concat(words, " · "), inner.width)
        viz.waffle(painter, {x = inner.x, y = inner.y + 2, width = inner.width, height = inner.height - 2}, roles)
    end
end

local function hosts_panel(snapshot: probe.Snapshot): Panel
    return function(painter: frame.Painter, cell: frame.Rect)
        local states: {string} = {}
        local hosts: {string} = {}
        for index, item in ipairs(snapshot.processes) do
            states[index] = text.bound(item.state, 64)
            hosts[index] = text.bound(item.host, 128)
        end
        local inner = frame.panel(painter, cell, "Hosts", plural(#tally(hosts), "host", "hosts"))
        local names: {string} = {}
        for index, item in ipairs(tally(states)) do if index <= 3 then names[index] = item.name end end
        local stacks: {viz.Stack} = {}
        for _, host in ipairs(tally(hosts)) do
            local segments: {number} = {}
            for position, name in ipairs(names) do
                local count = 0
                for index = 1, #snapshot.processes do
                    if hosts[index] == host.name and states[index] == name then count = count + 1 end
                end
                segments[position] = count
            end
            stacks[#stacks + 1] = {label = host.name, segments = segments}
        end
        if #stacks == 0 then frame.empty(painter, inner.y, "No hosts reported", "R retry", inner); return end
        viz.stacked(painter, inner, stacks, names)
    end
end

local function memory_panel(snapshot: probe.Snapshot): Panel
    return function(painter: frame.Painter, cell: frame.Rect)
        local inner = frame.panel(painter, cell, "Memory", snapshot.reserved and (viz.bytes(snapshot.reserved) .. " reserved") or "")
        if not snapshot.heap or not snapshot.reserved then frame.empty(painter, inner.y, "Memory statistics unavailable", "R retry", inner); return end
        viz.gauge(painter, inner.x, inner.y, inner.width, snapshot.heap or 0, snapshot.reserved or 1, {label = "Heap", warn = 0.8, error = 0.95})
        frame.put(painter, inner.x, inner.y + 2, viz.number(snapshot.heap_objects or viz.GAP) .. " objects · "
            .. viz.number(snapshot.gc_cycles or viz.GAP) .. " GC cycles", inner.width, painter.theme.muted)
    end
end

local function topology_panel(snapshot: probe.Snapshot): Panel
    return function(painter: frame.Painter, cell: frame.Rect)
        local hosts: {string} = {}
        for index, item in ipairs(snapshot.processes) do hosts[index] = text.bound(item.host, 128) end
        local counts = tally(hosts)
        local inner = frame.panel(painter, cell, "Topology", "this node")
        local nodes: {viz.Node} = {{id = "node", label = "node", note = plural(#counts, "host", "hosts")}}
        local edges: {viz.Edge} = {}
        for _, host in ipairs(counts) do
            nodes[#nodes + 1] = {id = host.name, label = host.name, note = plural(host.count, "process", "processes")}
            edges[#edges + 1] = {from = "node", to = host.name}
        end
        viz.graph(painter, inner, nodes, edges)
    end
end

local function steps_panel(snapshot: probe.Snapshot): Panel
    return function(painter: frame.Painter, cell: frame.Rect)
        local inner = frame.panel(painter, cell, "Steps per process", "distribution")
        local steps: {number} = {}
        for index, item in ipairs(snapshot.processes) do steps[index] = item.steps end
        if #steps == 0 then frame.empty(painter, inner.y, "No processes reported", "R retry", inner); return end
        viz.histogram(painter, inner, steps, 12, {min = 0})
    end
end

-- The dashboard frame for one size class.
function M.draw(width: integer, height: integer, preferences: appearance.Preferences, snapshot: probe.Snapshot,
    history: probe.History, paused: boolean): Frame
    local painter = frame.new(width, height, preferences)
    local layout = frame.layout(painter, false, true)
    local work = layout.work
    local summary = (paused and "Paused" or "Live · 1s") .. " · " .. plural(#snapshot.processes, "process", "processes")
    frame.header(painter, "SYSTEM MONITOR", summary)
    local error_text = text.bound(snapshot.error, 512)
    local grid = GRID[layout.size]
    local hosts: {string} = {}
    for index, item in ipairs(snapshot.processes) do hosts[index] = text.bound(item.host, 128) end
    local host_count = #tally(hosts)
    local latest_rate = viz.latest(history.rate)
    local rate = latest_rate and viz.number(latest_rate, "steps/s") or "—"
    if not grid or work.height < 12 then
        frame.line(painter, work.y, "Heap " .. (snapshot.heap and viz.bytes(snapshot.heap) or "—") .. " · " .. rate, painter.theme.text)
        if work.height >= 2 then
            frame.line(painter, work.y + 1, plural(#snapshot.services, "service", "services") .. " · "
                .. plural(host_count, "host", "hosts"), painter.theme.muted)
        end
    else
        viz.tiles(painter, {x = work.x, y = work.y, width = work.width, height = 3}, {
            {label = "Heap", value = snapshot.heap and viz.bytes(snapshot.heap) or "—", values = viz.values(history.heap)},
            {label = "Scheduler", value = rate, values = viz.values(history.rate)},
            {label = "Processes", value = viz.count(#snapshot.processes), note = "on " .. plural(host_count, "host", "hosts")},
            {label = "Goroutines", value = viz.number(snapshot.goroutines or viz.GAP), note = viz.number(snapshot.gc_cycles or viz.GAP) .. " GC"},
        })
        local panels: {Panel} = {heap_panel(snapshot, history), states_panel(snapshot), scheduler_panel(history),
            services_panel(snapshot), hosts_panel(snapshot), memory_panel(snapshot), topology_panel(snapshot), steps_panel(snapshot)}
        local cells = frame.grid({x = work.x, y = work.y + 4, width = work.width, height = work.height - 4}, grid[1], grid[2])
        for index, cell in ipairs(cells) do panels[index](painter, cell) end
    end
    if layout.actions > 0 then
        frame.actions(painter, layout.actions, {
            {kind = "refresh", label = "Refresh", key = "Enter", enabled = true, primary = true},
            {kind = "pause", label = paused and "Resume" or "Pause", key = "P", enabled = true, active = paused},
        })
    end
    if layout.footer > 0 then frame.footer(painter, error_text, HINTS) end
    return {rows = frame.rows(painter), hits = painter.hits}
end

return M
