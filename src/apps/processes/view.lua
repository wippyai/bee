local history_values = require("history_values")
-- Pure presentation of measured samples. No polling, process control or grants.
local appearance = require("appearance")
local frame = require("frame")
local probe = require("probe")
local text = require("text")
local viz = require("viz")
local hive = require("hive")
type Row = {pid: string, source: string, state: string, steps: integer?}
type Frame = {rows: {string}, hits: {frame.Hit}, controls: frame.Controls?, capacity: integer, offset: integer}
local M = {}
-- A service that exited without an error finished its work, as a boot gate
-- does; one that exited with an error stopped.
local function service_state(item: probe.Service): string
    if item.state == "exited" and not item.detail then return "done" end
    return item.state
end
-- Bee's own services are listed by title in title order; the runtime's
-- services fold into one row that counts them by state.
function M.items(snapshot: probe.Snapshot, services: boolean): {Row}
    local rows: {Row} = {}
    if services then
        local runtime: {[string]: integer} = {}
        local runtime_restarts = 0
        local runtime_count = 0
        for _, item in ipairs(snapshot.services) do
            local state = service_state(item)
            if item.id:sub(1, 4) == "bee." then
                rows[#rows + 1] = {pid = item.id, source = item.title or item.id, state = state, steps = item.restarts}
            else
                runtime[state] = (runtime[state] or 0) + 1
                runtime_restarts = runtime_restarts + (item.restarts or 0)
                runtime_count = runtime_count + 1
            end
        end
        table.sort(rows, function(left: Row, right: Row): boolean return left.source:lower() < right.source:lower() end)
        if runtime_count > 0 then
            local parts: {string} = {}
            local states: {string} = {}
            for state in pairs(runtime) do states[#states + 1] = state end
            table.sort(states, function(left: string, right: string): boolean
                if left == "running" or right == "running" then return left == "running" end
                return left < right
            end)
            for _, state in ipairs(states) do parts[#parts + 1] = tostring(runtime[state]) .. " " .. state end
            rows[#rows + 1] = {pid = "runtime", source = "Runtime", state = table.concat(parts, " · "), steps = runtime_restarts}
        end
    else
        for _, item in ipairs(snapshot.processes) do
            rows[#rows + 1] = {pid = item.pid, source = item.source, state = item.state, steps = item.steps}
        end
    end
    return rows
end
-- A PID's local suffix ("0x00017" in "{node@host|0x00017}") names one of
-- several processes from the same source.
function M.pid_suffix(pid: string): string
    local suffix = pid:match("|([^|}]+)}?$")
    if suffix and suffix ~= "" then return suffix end
    return pid:sub(math.floor(math.max(1, #pid - 7)))
end
local function number(value: number?): string
    if value == nil or viz.is_gap(value) or value < 0 then return "—" end
    return string.format("%.0f", value)
end
-- The panes: this node's processes and services, and the hive's nodes.
local TABS = {{kind = "processes", label = "Processes", short = "Proc"}, {kind = "services", label = "Services", short = "Svc"},
    {kind = "hive", label = "Hive", short = "Hive"}}
local HIVE_HINTS = frame.hints({{key = "Tab", verb = "switch"}, {key = "Esc", verb = "close"}})
local HIVE_MORE = frame.hints({{key = "↑↓", verb = "select"}, {key = "P", verb = "pause"}})
-- The footer names only keys the buttons above it do not show; help lists
-- them all.
local HINTS = frame.hints({{key = "Tab", verb = "switch"}, {key = "Esc", verb = "close"}})
local MORE = frame.hints({{key = "↑↓", verb = "select"}, {key = "S", verb = "sort"}, {key = "P", verb = "pause"}, {key = "Del", verb = "stop"}})
function M.draw(width: integer, height: integer, snapshot: probe.Snapshot, history: history_values.History,
    preferences: appearance.Preferences, selected: string, offset: integer, paused: boolean,
    status: string, confirming: boolean, services: boolean, rows: {Row}, by_steps: boolean): Frame
    local painter = frame.new(width, height, preferences)
    local theme = painter.theme
    local noun = services and (#rows == 1 and " service" or " services") or (#rows == 1 and " process" or " processes")
    frame.header(painter, "PROCESS MANAGER", (paused and "Paused" or "Live · 1s") .. " · " .. tostring(#rows) .. noun)
    frame.tabs(painter, 2, TABS, services and "services" or "processes")
    local first = 4
    if width >= 48 and height >= 14 then
        local col = math.floor((width - 3) / 2)
        local function metric(index: integer, title: string, value: string, values: viz.Series)
            local x = 2 + (index - 1) * (col + 1)
            frame.section(painter, 4, title, nil, {x = x, y = 4, width = col, height = 1})
            frame.put(painter, x, 5, value, col)
            viz.sparkline(painter, x, 6, col, viz.values(values))
        end
        metric(1, "Heap", snapshot.heap and string.format("%.1f MiB", snapshot.heap / 1048576) or "—", history.heap)
        local last = viz.latest(history.rate)
        metric(2, "Scheduler", number(last) .. " steps/s", history.rate)
        frame.line(painter, 7, number(snapshot.goroutines) .. " goroutines · " .. number(snapshot.gc_cycles) .. " GC · "
            .. (snapshot.reserved and string.format("%.1f MiB reserved", snapshot.reserved / 1048576) or "—"), theme.muted)
        first = 9
    elseif height >= 6 then
        frame.line(painter, 3, "Heap " .. (snapshot.heap and string.format("%.1f MiB", snapshot.heap / 1048576) or "—"), theme.muted)
    end
    local source_counts: {[string]: integer} = {}
    for _, item in ipairs(rows) do
        if item.source ~= "" then source_counts[item.source] = (source_counts[item.source] or 0) + 1 end
    end
    local cells: {{string}} = {}
    local keys: {string} = {}
    local selected_index = 0
    for index, item in ipairs(rows) do
        local label = text.bound(item.source ~= "" and item.source or item.pid, 512)
        if item.source ~= "" and (source_counts[item.source] or 0) > 1 then
            label = label .. " · " .. text.bound(M.pid_suffix(item.pid), 64)
        end
        cells[index] = {label, text.bound(item.state, 64), number(item.steps)}
        keys[index] = item.pid
        if item.pid == selected then selected_index = index end
    end
    local detail_y = height >= 10 and height - 2 or 0
    local last = (detail_y > 0 and detail_y or height - 1) - 1
    local columns: {frame.Column} = {{title = services and "Service" or "Process", width = 0}, {title = "State", width = 10},
        {title = services and "Restarts" or "Steps", width = 10, align = "right"}}
    local window = frame.table(painter, first, last, {columns = columns, cells = cells, keys = keys, kind = "row",
        selected = selected_index, offset = offset})
    if #rows == 0 then frame.empty(painter, first + 1, services and "No services" or "No processes", paused and "P resume updates" or "Apps appear here while they are running") end
    if detail_y > 0 and selected_index > 0 then
        frame.fill(painter, detail_y)
        local label = services and "Service" or "PID"
        frame.put(painter, 2, detail_y, label, 8, theme.muted)
        frame.put(painter, 11, detail_y, text.bound(selected, 512), width - 11, theme.text)
    end
    if height >= 3 then
        frame.actions(painter, height - 1, {
            {kind = "pause", key = "P", label = paused and "Resume" or "Pause", enabled = true, active = paused},
            {kind = "sort", key = "S", label = by_steps and (services and "Sort: restarts" or "Sort: steps") or "Sort: name", enabled = true},
            {kind = "stop", key = "Del", label = "Stop app", enabled = not services and selected ~= "", primary = confirming},
        })
    end
    local footer = text.bound(status ~= "" and status or (snapshot.error or ""), 512)
    if confirming then footer = "Stop selected app?" end
    frame.footer(painter, footer, confirming and "Enter confirms · Esc cancels" or HINTS, MORE)
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter), capacity = window.capacity, offset = window.offset}
end

local function mib(value: number?): string
    if value == nil or viz.is_gap(value) then return "—" end
    return string.format("%.1f MiB", value / 1048576)
end

local function in_mib(values: {number}): {number}
    local scaled: {number} = {}
    for index, value in ipairs(values) do scaled[index] = viz.is_gap(value) and value or value / 1048576 end
    return scaled
end

-- draw_hive shows the hive's nodes: heap and goroutine charts with one line
-- per node, then a row per node with its latest numbers.
function M.draw_hive(width: integer, height: integer, nodes: {hive.Node}, preferences: appearance.Preferences,
    selected: string, offset: integer, paused: boolean, status: string): Frame
    local painter = frame.new(width, height, preferences)
    local theme = painter.theme
    local online = 0
    for _, item in ipairs(nodes) do if item.online then online = online + 1 end end
    frame.header(painter, "PROCESS MANAGER", (paused and "Paused" or "Live · 1s") .. " · " .. tostring(online) .. " of "
        .. tostring(#nodes) .. (#nodes == 1 and " node" or " nodes"))
    frame.tabs(painter, 2, TABS, "hive")
    local first = 4
    if width >= 48 and height >= 18 and #nodes > 0 then
        local col = math.floor((width - 3) / 2)
        local chart_height = math.floor(math.max(4, math.min(8, height - 14)))
        local heap_lines: {viz.Line} = {}
        local goroutine_lines: {viz.Line} = {}
        local keys: {viz.Key} = {}
        for _, item in ipairs(nodes) do
            heap_lines[#heap_lines + 1] = {values = in_mib(viz.values(item.heap)), label = item.name}
            goroutine_lines[#goroutine_lines + 1] = {values = viz.values(item.goroutines), label = item.name}
            keys[#keys + 1] = {label = item.name}
        end
        frame.section(painter, 4, "Heap", nil, {x = 2, y = 4, width = col, height = 1})
        viz.line(painter, {x = 2, y = 5, width = col - 1, height = chart_height}, heap_lines, {unit = "MiB"})
        frame.section(painter, 4, "Goroutines", nil, {x = 3 + col, y = 4, width = col, height = 1})
        viz.line(painter, {x = 3 + col, y = 5, width = col, height = chart_height}, goroutine_lines)
        viz.legend(painter, 2, 5 + chart_height, width - 3, keys)
        first = 7 + chart_height
    end
    local cells: {{string}} = {}
    local keys_by_row: {string} = {}
    local selected_index = 0
    for index, item in ipairs(nodes) do
        local latest = item.latest
        local state = item.here and "this node" or (item.online and "online" or "away")
        cells[index] = {text.bound(item.name, 80), state, mib(latest.heap),
            latest.goroutines and string.format("%.0f", latest.goroutines) or "—",
            latest.apps and string.format("%.0f", latest.apps) or "—"}
        keys_by_row[index] = item.node
        if item.node == selected then selected_index = index end
    end
    local detail_y = height >= 10 and height - 2 or 0
    local last = (detail_y > 0 and detail_y or height - 1) - 1
    frame.section(painter, first, "Nodes", tostring(#nodes), nil)
    local columns: {frame.Column} = {{title = "Node", width = 0}, {title = "State", width = 10},
        {title = "Heap", width = 12, align = "right"}, {title = "Goroutines", width = 11, align = "right"},
        {title = "Apps", width = 6, align = "right"}}
    local window = frame.table(painter, first + 1, last, {columns = columns, cells = cells, keys = keys_by_row, kind = "row",
        selected = selected_index, offset = offset})
    if #nodes == 0 then frame.empty(painter, first + 2, "No nodes answered yet", "Nodes of the hive appear as they answer") end
    if detail_y > 0 and selected_index > 0 then
        local item = nodes[selected_index]
        frame.fill(painter, detail_y)
        frame.put(painter, 2, detail_y, "Node", 8, theme.muted)
        local note = item.latest.error and (" · " .. item.latest.error) or ""
        frame.put(painter, 11, detail_y, text.bound(item.node .. note, 512), width - 11, theme.text)
    end
    if height >= 3 then
        frame.actions(painter, height - 1, {
            {kind = "pause", key = "P", label = paused and "Resume" or "Pause", enabled = true, active = paused},
        })
    end
    frame.footer(painter, text.bound(status, 512), HIVE_HINTS, HIVE_MORE)
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter), capacity = window.capacity, offset = window.offset}
end
return M
