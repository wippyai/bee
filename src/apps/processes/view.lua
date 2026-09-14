-- Pure presentation of measured samples. No polling, process control or grants.
local tty = require("tty")
local appearance = require("appearance")
local probe = require("probe")
local text = require("text")
type Row = {pid: string, source: string, state: string, steps: number}
type Frame = {rows: {string}, first: integer, capacity: integer, offset: integer}
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
local bars: {string} = {"▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"}
function M.spark(values: {number}, width: integer): string
    local peak = 1
    local first = math.floor(math.max(1, #values - width + 1))
    for index = first, #values do peak = math.max(peak, values[index]) end
    local out = string.rep(" ", math.floor(math.max(0, width - #values)))
    for index = first, #values do
        local value = values[index]
        out = out .. (value < 0 and "·" or bars[math.floor(math.min(8, math.max(1, math.ceil(value / peak * 8))))])
    end
    return out
end
local function number(value: number?): string
    if value == nil or value < 0 then return "—" end
    return string.format("%.0f", value)
end
function M.draw(width: integer, height: integer, snapshot: probe.Snapshot, history: probe.History,
    preferences: appearance.Preferences, selected: string, offset: integer, paused: boolean,
    status: string, confirming: boolean, services: boolean, rows: {Row}, by_steps: boolean): Frame
    local theme = appearance.theme(preferences.theme)
    local canvas = tty.canvas(width, height)
    local function put(x: integer, y: integer, text: string, size: integer, fg: string?, bg: string?)
        if y >= 1 and y <= height and size > 0 then
            canvas:put(x, y, appearance.style(fg or theme.text, bg or theme.surface) .. text .. "\27[0m", size)
        end
    end
    canvas:clear(appearance.style(theme.text, theme.surface) .. " \27[0m")
    local state = paused and "Paused" or "Live · 1s"
    if width < 26 then
        local label = services and " Services " or " Processes "
        put(2, 1, label, #label, appearance.selection_text(theme), theme.accent)
    else
        put(2, 1, " Processes ", 11, services and theme.muted or appearance.selection_text(theme), services and theme.surface or theme.accent)
        put(14, 1, " Services ", 10, services and appearance.selection_text(theme) or theme.muted, services and theme.accent or theme.surface)
    end
    if height >= 13 and width >= 48 then
        put(2, 2, state .. "  ·  " .. tostring(#rows) .. (services and " services" or " processes"), width - 2, theme.muted)
    end
    if width >= 38 then put(width - 10, 1, paused and " Resume " or " Pause ", 9, theme.accent) end
    local first = 4
    if width >= 48 and height >= 13 then
        local col = math.floor((width - 3) / 2)
        local function metric(index: integer, title: string, value: string, values: {number})
            local x = 2 + (index - 1) * (col + 1)
            put(x, 3, title, col, theme.muted)
            put(x, 4, value, col)
            put(x, 5, M.spark(values, col), col, theme.accent)
        end
        metric(1, "Heap", snapshot.heap and string.format("%.1f MiB", snapshot.heap / 1048576) or "—", history.heap)
        local last = history.rate[#history.rate]
        metric(2, "Scheduler", number(last) .. " steps/s", history.rate)
        put(2, 7, number(snapshot.goroutines) .. " goroutines · " .. number(snapshot.gc_cycles) .. " GC · "
            .. (snapshot.reserved and string.format("%.1f MiB reserved", snapshot.reserved / 1048576) or "—"), width - 2, theme.muted)
        first = 10
    else
        put(2, 2, "Heap " .. (snapshot.heap and string.format("%.1fM", snapshot.heap / 1048576) or "—"), width - 2, theme.muted)
    end
    local capacity = math.floor(math.max(0, height - first - 2))
    local next_offset = math.floor(math.max(0, math.min(offset, #rows - capacity)))
    local source_counts: {[string]: integer} = {}
    for _, item in ipairs(rows) do
        if item.source ~= "" then source_counts[item.source] = (source_counts[item.source] or 0) + 1 end
    end
    put(2, first - 1, services and "SERVICE" or "PROCESS", math.floor(math.max(0, width - 22)), theme.muted)
    if width >= 38 then put(width - 21, first - 1, services and "STATE      RESTARTS" or "STATE         STEPS", 21, theme.muted) end
    for row = 1, capacity do
        local item = rows[next_offset + row]
        if item then
            local active = item.pid == selected
            local fg, bg = active and appearance.selection_text(theme) or theme.text, active and theme.accent or theme.surface
            put(1, first + row - 1, string.rep(" ", width), width, fg, bg)
            local room = math.floor(math.max(1, width >= 38 and width - 24 or width - 2))
            local label = text.bound(item.source ~= "" and item.source or item.pid, 512)
            if item.source ~= "" and (source_counts[item.source] or 0) > 1 then
                local safe_pid = text.bound(item.pid, 512)
                label = label .. " · " .. safe_pid:sub(math.max(1, #safe_pid - 7))
            end
            local item_state = text.bound(item.state, 64)
            if width < 38 then label = label .. " · " .. item_state end
            put(2, first + row - 1, tty.text.truncate(label, room, "…"), room, fg, bg)
            if width >= 38 then
                put(width - 21, first + row - 1, tty.text.truncate(item_state, 10, "…"), 10, fg, bg)
                put(width - 10, first + row - 1, string.format("%10.0f", item.steps), 10, fg, bg)
            end
        end
    end
    local detail = ""
    for _, item in ipairs(rows) do if item.pid == selected then detail = item.pid; break end end
    put(2, height - 1, text.bound(detail, 512), width - 2, theme.muted)
    local footer = text.bound(status ~= "" and status or (snapshot.error or ""), 512)
    if confirming then footer = "Stop selected app? Enter confirms · Esc cancels"
    end
    if footer == "" then
        put(2, height, by_steps and (services and " Sort: restarts " or " Sort: steps ") or " Sort: name ", math.floor(math.max(0, width - 13)), theme.accent)
        if not services then put(math.floor(math.max(1, width - 10)), height, " Stop app ", 10, selected ~= "" and theme.accent or theme.muted) end
    else put(2, height, footer, width - 2, confirming and theme.accent or theme.muted) end
    return {rows = canvas:rows(), first = first, capacity = capacity, offset = next_offset}
end
return M
