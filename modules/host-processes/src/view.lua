-- Pure presentation of measured samples. No polling, process control or grants.
local appearance = require("appearance")
local frame = require("frame")
local probe = require("probe")
local text = require("text")
local viz = require("viz")
type Row = {pid: string, source: string, state: string, steps: number}
type Frame = {rows: {string}, hits: {frame.Hit}, capacity: integer, offset: integer}
local M = {}
function M.items(snapshot: probe.Snapshot, services: boolean): {Row}
    local rows: {Row} = {}
    if services then
        for _, item in ipairs(snapshot.services) do
            rows[#rows + 1] = {pid = item.id, source = item.id, state = item.state, steps = item.restarts}
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
local HINTS = frame.hints({{key = "↑↓", verb = "select"}, {key = "Tab", verb = "switch"}, {key = "S", verb = "sort"},
    {key = "P", verb = "pause"}, {key = "Del", verb = "stop"}, {key = "Esc", verb = "close"}})
function M.draw(width: integer, height: integer, snapshot: probe.Snapshot, history: probe.History,
    preferences: appearance.Preferences, selected: string, offset: integer, paused: boolean,
    status: string, confirming: boolean, services: boolean, rows: {Row}, by_steps: boolean): Frame
    local painter = frame.new(width, height, preferences)
    local theme = painter.theme
    local noun = services and (#rows == 1 and " service" or " services") or (#rows == 1 and " process" or " processes")
    frame.header(painter, "PROCESS MANAGER", (paused and "Paused" or "Live · 1s") .. " · " .. tostring(#rows) .. noun)
    frame.tabs(painter, 2, {{kind = "processes", label = "Processes", short = "Proc"}, {kind = "services", label = "Services", short = "Svc"}},
        services and "services" or "processes")
    local first = 4
    if width >= 48 and height >= 14 then
        local col = math.floor((width - 3) / 2)
        local function metric(index: integer, title: string, value: string, values: viz.Series)
            local x = 2 + (index - 1) * (col + 1)
            frame.put(painter, x, 4, title, col, theme.muted)
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
        cells[index] = {label, text.bound(item.state, 64), string.format("%.0f", item.steps)}
        keys[index] = item.pid
        if item.pid == selected then selected_index = index end
    end
    local detail_y = height >= 10 and height - 2 or 0
    local last = (detail_y > 0 and detail_y or height - 1) - 1
    local columns: {frame.Column} = {{title = services and "Service" or "Process", width = 0}, {title = "State", width = 10},
        {title = services and "Restarts" or "Steps", width = 10, align = "right"}}
    local window = frame.table(painter, first, last, {columns = columns, cells = cells, keys = keys, kind = "row",
        selected = selected_index, offset = offset})
    if detail_y > 0 and selected_index > 0 then frame.line(painter, detail_y, text.bound(selected, 512), theme.muted) end
    if height >= 3 then
        frame.actions(painter, height - 1, {
            {kind = "pause", label = paused and "Resume" or "Pause", enabled = true, active = paused},
            {kind = "sort", label = by_steps and (services and "Sort: restarts" or "Sort: steps") or "Sort: name", enabled = true},
            {kind = "stop", label = "Stop app", enabled = not services and selected ~= "", primary = confirming},
        })
    end
    local footer = text.bound(status ~= "" and status or (snapshot.error or ""), 512)
    if confirming then footer = "Stop selected app? Enter confirms · Esc cancels" end
    frame.footer(painter, footer, confirming and "" or HINTS)
    return {rows = frame.rows(painter), hits = painter.hits, capacity = window.capacity, offset = window.offset}
end
return M
