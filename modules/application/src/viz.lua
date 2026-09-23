-- MIT. The visualization kit: sparklines, line and area charts, bars, stacked
-- bars, histograms, heatmaps, status grids, gauges, progress, stat tiles,
-- inline table bars, timelines, small node-edge graphs and the bounded live
-- series behind them. Pure: every drawing function paints inside the
-- rectangle it is given through the application frame, reads colors from
-- semantic roles and keeps no state between frames.
local tty = require("tty")
local appearance = require("appearance")
local frame = require("frame")
local M = {}

-- A missing sample. It draws as a gap and never as zero.
M.GAP = 0 / 0
-- The most nodes and edges one graph lays out; the rest are not drawn.
M.GRAPH_NODES = 64
M.GRAPH_EDGES = 256

type Rect = frame.Rect
-- A bounded ring of samples, oldest first; total counts every push.
type Series = {capacity: integer, items: {number}, first: integer, count: integer, total: integer}
-- A redraw clock: due answers true at most once per interval.
type Cadence = {interval: integer, next_at: integer}
-- One series of a line or area chart. role defaults to accent, text, muted by position.
type Line = {values: {number}, role: string?, label: string?}
-- Scale and axis labels of a chart. from and to label the ends of the time axis.
type Chart = {min: number?, max: number?, area: boolean?, unit: string?, from: string?, to: string?}
-- One bar or column. note replaces the printed value when present.
type Bar = {label: string, value: number, role: string?, note: string?}
-- Scale of a bar chart; values at or past warn or error take that status role.
type Scale = {max: number?, unit: string?, warn: number?, error: number?}
-- One stacked row: segment values in the order of the legend names.
type Stack = {label: string, segments: {number}}
-- A heatmap grid in rows of numbers with optional row and column labels.
type Grid = {rows: {{number}}, row_labels: {string}?, column_labels: {string}?, max: number?, role: string?}
-- A labelled meter; label is drawn muted before the bar.
type Meter = {label: string?, unit: string?, warn: number?, error: number?}
-- A headline number: muted label, value, optional muted note and optional trend.
type Tile = {label: string, value: string, note: string?, role: string?, values: {number}?}
-- A span on a timeline lane, in the caller's time unit.
type Span = {start: number, finish: number, role: string?}
type Lane = {label: string, spans: {Span}}
type Window = {from: number, to: number, now: number?, from_label: string?, to_label: string?}
-- A graph node and a directed edge between node ids.
type Node = {id: string, label: string, role: string?, note: string?}
type Edge = {from: string, to: string}
-- A legend key: glyph in role before the label.
type Key = {label: string, role: string?, glyph: string?}

local EIGHTHS_UP: {string} = {"▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"}
local EIGHTHS_RIGHT: {string} = {"▏", "▎", "▍", "▌", "▋", "▊", "▉", "█"}
local SHADES: {string} = {"█", "▓", "▒", "░"}
local RAMP: {string} = {"░", "▒", "▓", "█"}
local SERIES_ROLES: {string} = {"accent", "text", "muted"}
local STACK_ROLES: {string} = {"accent", "text", "muted", "border"}

local function maximum(a: integer, b: integer): integer if a > b then return a end; return b end
local function minimum(a: integer, b: integer): integer if a < b then return a end; return b end
local function clamp(value: integer, low: integer, high: integer): integer return maximum(low, minimum(high, value)) end
local function round(value: number): integer return math.floor(value + 0.5) end

-- True for a missing sample.
function M.is_gap(value: number): boolean
    return value ~= value
end

-- An empty series holding at most capacity samples.
function M.series(capacity: integer): Series
    return {capacity = maximum(1, capacity), items = {}, first = 1, count = 0, total = 0}
end

-- Appends one sample, dropping the oldest when the series is full.
function M.push(series: Series, value: number)
    if series.count < series.capacity then
        series.items[(series.first + series.count - 1) % series.capacity + 1] = value
        series.count = series.count + 1
    else
        series.items[series.first] = value
        series.first = series.first % series.capacity + 1
    end
    series.total = series.total + 1
end

-- The samples oldest first, as a new list of at most capacity values.
function M.values(series: Series): {number}
    local result: {number} = {}
    for index = 0, series.count - 1 do
        result[index + 1] = series.items[(series.first + index - 1) % series.capacity + 1]
    end
    return result
end

-- The newest sample, or nil when the series is empty.
function M.latest(series: Series): number?
    if series.count == 0 then return nil end
    return series.items[(series.first + series.count - 2) % series.capacity + 1]
end

-- A redraw clock with interval_ms between frames; the first call to due is true.
function M.cadence(interval_ms: integer): Cadence
    return {interval = maximum(1, interval_ms), next_at = 0}
end

-- True when a frame is due at now_ms, then schedules the next one on the
-- interval grid. Samples arriving between frames are pushed, not drawn.
function M.due(cadence: Cadence, now_ms: integer): boolean
    if now_ms < cadence.next_at then return false end
    if cadence.next_at == 0 or now_ms - cadence.next_at >= cadence.interval then
        cadence.next_at = now_ms + cadence.interval
    else
        cadence.next_at = cadence.next_at + cadence.interval
    end
    return true
end

-- The finite range of values, widened by min and max when given. Without
-- samples it is 0..1; a flat range grows by one above its value.
function M.extent(values: {number}, min: number?, max: number?): (number, number)
    local low: number? = min
    local high: number? = max
    local seen_low: number? = nil
    local seen_high: number? = nil
    for _, value in ipairs(values) do
        if not M.is_gap(value) then
            if seen_low == nil or value < seen_low then seen_low = value end
            if seen_high == nil or value > seen_high then seen_high = value end
        end
    end
    local result_low: number = low or math.min(0, seen_low or 0)
    local result_high: number = high or seen_high or 1
    if result_high <= result_low then result_high = result_low + 1 end
    return result_low, result_high
end

local function trimmed(value: number, decimals: integer): string
    local text = string.format("%." .. tostring(decimals) .. "f", value + 0.0)
    if decimals > 0 then text = text:gsub("0+$", ""):gsub("%.$", "") end
    return text
end

-- A compact number: 7, 7.5, 42, 1.2k, 12k, 3.4M, 1.1G, with an optional unit
-- after one space. A gap is "—".
function M.number(value: number, unit: string?): string
    if M.is_gap(value) then return "—" end
    local magnitude = math.abs(value)
    local text = ""
    local suffixes: {string} = {"k", "M", "G", "T"}
    if magnitude < 1000 then
        text = trimmed(value, magnitude < 10 and 1 or 0)
    else
        local scaled = value
        local suffix = ""
        for _, name in ipairs(suffixes) do
            if math.abs(scaled) < 999.5 then break end
            scaled = scaled / 1000
            suffix = name
        end
        text = trimmed(scaled, math.abs(scaled) < 10 and 1 or 0) .. suffix
    end
    if unit and unit ~= "" then return text .. " " .. unit end
    return text
end

-- A byte count in binary units: 512 B, 12.4 KiB, 3.1 MiB, 1.5 GiB.
function M.bytes(value: number): string
    if M.is_gap(value) then return "—" end
    local units: {string} = {"KiB", "MiB", "GiB", "TiB"}
    if math.abs(value) < 1024 then return string.format("%.0f B", value + 0.0) end
    local scaled = value
    local unit = "B"
    for _, name in ipairs(units) do
        if math.abs(scaled) < 1024 then break end
        scaled = scaled / 1024
        unit = name
    end
    return string.format("%.1f %s", scaled + 0.0, unit)
end

-- A whole count with thousands separators: 4,000. A gap is "—".
function M.count(value: number): string
    if M.is_gap(value) then return "—" end
    local digits = string.format("%.0f", math.abs(value) + 0.0)
    local groups: {string} = {}
    local last = #digits
    while last > 0 do
        groups[#groups + 1] = digits:sub(maximum(1, last - 2), last)
        last = last - 3
    end
    local ordered: {string} = {}
    for index = #groups, 1, -1 do ordered[#ordered + 1] = groups[index] end
    return (value < 0 and "-" or "") .. table.concat(ordered, ",")
end

local function color(painter: frame.Painter, role: string?, fallback: string): string
    return appearance.role(painter.theme, role or fallback)
end

local function status_role(value: number, warn: number?, error_at: number?, fallback: string): string
    if error_at and value >= error_at then return "error" end
    if warn and value >= warn then return "warn" end
    return fallback
end

-- The newest width samples as one row of ▁…█ scaled between min (default the
-- lower of 0 and the smallest sample) and max (default the largest sample),
-- right-aligned with leading spaces; a gap is "·".
function M.spark(values: {number}, width: integer, min: number?, max: number?): string
    if width <= 0 then return "" end
    local first = maximum(1, #values - width + 1)
    local window: {number} = {}
    for index = first, #values do window[#window + 1] = values[index] end
    local low, high = M.extent(window, min, max)
    local parts: {string} = {string.rep(" ", width - #window)}
    for _, value in ipairs(window) do
        if M.is_gap(value) then parts[#parts + 1] = "·"
        else parts[#parts + 1] = EIGHTHS_UP[clamp(math.ceil((value - low) / (high - low) * 8), 1, 8)] end
    end
    return table.concat(parts)
end

-- A sparkline at (x, y) over width cells in role (default accent).
function M.sparkline(painter: frame.Painter, x: integer, y: integer, width: integer, values: {number}, role: string?, min: number?, max: number?)
    frame.clip(painter, x, y, M.spark(values, width, min, max), width, color(painter, role, "accent"))
end

-- A proportional bar of width cells for value out of max in eighth blocks,
-- padded with spaces: the inline bar of a table cell.
function M.bar_cell(value: number, max: number, width: integer): string
    if width <= 0 then return "" end
    local eighths = 0
    if not M.is_gap(value) and max > 0 then eighths = clamp(round(value / max * width * 8), 0, width * 8) end
    local full = eighths // 8
    local rest = eighths % 8
    local text = string.rep("█", full) .. (rest > 0 and EIGHTHS_RIGHT[rest] or "")
    return text .. string.rep(" ", width - full - (rest > 0 and 1 or 0))
end

-- One legend row: each key as its glyph (default █) in its role and its label,
-- two cells apart. Returns the drawn width.
function M.legend(painter: frame.Painter, x: integer, y: integer, width: integer, keys: {Key}): integer
    local column = x
    local limit = x + width
    for index, key in ipairs(keys) do
        local glyph = key.glyph or SHADES[(index - 1) % #SHADES + 1]
        local label = key.label
        local size = tty.text.width(glyph) + 1 + tty.text.width(label)
        if column + size > limit then break end
        frame.clip(painter, column, y, glyph, 1, color(painter, key.role, STACK_ROLES[(index - 1) % #STACK_ROLES + 1]))
        frame.put(painter, column + 2, y, label, limit - column - 2, painter.theme.muted)
        column = column + size + 2
    end
    return column - x
end

-- Braille dot bits for (column 0..1, row 0..3 from the top).
local DOTS: {{integer}} = {{0x01, 0x02, 0x04, 0x40}, {0x08, 0x10, 0x20, 0x80}}

-- The braille cell U+2800 + bits, encoded as its three UTF-8 bytes.
local function braille(bits: integer): string
    return string.char(0xE2, 0xA0 + bits // 64, 0x80 + bits % 64)
end

-- A line or area chart in rect: y-axis labels at the top and bottom rows of
-- the plot, an axis row, and the from/to labels below when given. Lines use
-- braille dots (two samples per cell); the second and third series are
-- dotted. With area the first series fills in eighth blocks, one sample per
-- cell. A rect under 4 rows draws the first series as a sparkline.
function M.line(painter: frame.Painter, rect: Rect, lines: {Line}, options: Chart?)
    if rect.width <= 0 or rect.height <= 0 or #lines == 0 then return end
    local chart: Chart = options or {}
    if rect.height < 4 then
        M.sparkline(painter, rect.x, rect.y, rect.width, lines[1].values, lines[1].role, chart.min, chart.max)
        return
    end
    local all: {number} = {}
    for _, line in ipairs(lines) do for _, value in ipairs(line.values) do all[#all + 1] = value end end
    local low, high = M.extent(all, chart.min, chart.max)
    local top_label = M.number(high, chart.unit)
    local bottom_label = M.number(low, chart.unit)
    local label_width = maximum(tty.text.width(top_label), tty.text.width(bottom_label))
    local labelled = (chart.from ~= nil or chart.to ~= nil)
    local plot_height = rect.height - 1 - (labelled and 1 or 0)
    local plot_x = rect.x + label_width + 2
    local plot_width = rect.x + rect.width - plot_x
    if plot_width < 2 then
        M.sparkline(painter, rect.x, rect.y, rect.width, lines[1].values, lines[1].role, chart.min, chart.max)
        return
    end
    local theme = painter.theme
    for row = 0, plot_height - 1 do
        local y = rect.y + row
        local tick = (row == 0 or row == plot_height - 1)
        if row == 0 then frame.put(painter, rect.x, y, frame.pad(top_label, label_width, "right"), label_width, theme.muted) end
        if row == plot_height - 1 then frame.put(painter, rect.x, y, frame.pad(bottom_label, label_width, "right"), label_width, theme.muted) end
        frame.clip(painter, plot_x - 1, y, tick and "┤" or "│", 1, theme.muted)
    end
    local axis_y = rect.y + plot_height
    frame.clip(painter, plot_x - 1, axis_y, "└" .. string.rep("─", plot_width), plot_width + 1, theme.muted)
    if labelled then
        local from = chart.from or ""
        local to = chart.to or ""
        frame.put(painter, plot_x, axis_y + 1, from, plot_width, theme.muted)
        local size = tty.text.width(frame.fit(to, plot_width))
        if size > 0 and size + tty.text.width(from) + 1 <= plot_width then
            frame.put(painter, plot_x + plot_width - size, axis_y + 1, to, size, theme.muted)
        end
    end
    local span = high - low
    for index, line in ipairs(lines) do
        local fg = color(painter, line.role, SERIES_ROLES[(index - 1) % #SERIES_ROLES + 1])
        if chart.area and index == 1 then
            local first = maximum(1, #line.values - plot_width + 1)
            local offset = plot_width - (#line.values - first + 1)
            for column = 0, plot_width - 1 do
                local value = line.values[first + column - offset]
                if value ~= nil and not M.is_gap(value) then
                    local eighths = clamp(round((value - low) / span * plot_height * 8), 1, plot_height * 8)
                    for row = 0, plot_height - 1 do
                        local level = eighths - (plot_height - 1 - row) * 8
                        if level > 0 then
                            frame.clip(painter, plot_x + column, rect.y + row, EIGHTHS_UP[minimum(8, level)], 1, fg)
                        end
                    end
                end
            end
        else
            local dots_x = plot_width * 2
            local dots_y = plot_height * 4
            local cells: {[integer]: integer} = {}
            local first = maximum(1, #line.values - dots_x + 1)
            local offset = dots_x - (#line.values - first + 1)
            local previous: integer? = nil
            for dot = 0, dots_x - 1 do
                local value = line.values[first + dot - offset]
                if value == nil or M.is_gap(value) then previous = nil
                else
                    local level = clamp(round((value - low) / span * (dots_y - 1)), 0, dots_y - 1)
                    local from_level = previous or level
                    local step = from_level <= level and 1 or -1
                    if index == 1 or dot % 2 == 0 then
                        for fill = from_level, level, step do
                            local dot_row = dots_y - 1 - fill
                            local key = (dot_row // 4) * plot_width + dot // 2
                            cells[key] = (cells[key] or 0) | DOTS[dot % 2 + 1][dot_row % 4 + 1]
                        end
                    end
                    previous = level
                end
            end
            for key, bits in pairs(cells) do
                frame.clip(painter, plot_x + key % plot_width, rect.y + key // plot_width, braille(bits), 1, fg)
            end
        end
    end
end

local function bar_value(item: Bar, unit: string?): string
    return item.note or M.number(item.value, unit)
end

-- Horizontal bars, one item per row: the label, the bar in eighth blocks
-- scaled to max (default the largest value) and the value right-aligned at
-- the end. Items past the last row fold into a muted "+N more".
function M.bars(painter: frame.Painter, rect: Rect, items: {Bar}, options: Scale?)
    if rect.width <= 0 or rect.height <= 0 then return end
    local scale: Scale = options or {}
    local peak = scale.max or 0
    local label_width, value_width = 0, 0
    for _, item in ipairs(items) do
        if not scale.max and not M.is_gap(item.value) and item.value > peak then peak = item.value end
        label_width = maximum(label_width, tty.text.width(item.label))
        value_width = maximum(value_width, tty.text.width(bar_value(item, scale.unit)))
    end
    label_width = minimum(minimum(label_width, maximum(4, rect.width // 3)), rect.width)
    local bar_width = rect.width - label_width - value_width - 4
    local rows = #items > rect.height and rect.height - 1 or #items
    for index = 1, rows do
        local item = items[index]
        local y = rect.y + index - 1
        frame.put(painter, rect.x, y, item.label, label_width)
        if bar_width > 0 then
            local role = item.role or status_role(item.value, scale.warn, scale.error, "accent")
            frame.clip(painter, rect.x + label_width + 2, y, M.bar_cell(item.value, peak, bar_width), bar_width, color(painter, role, "accent"))
        end
        local value = bar_value(item, scale.unit)
        local size = tty.text.width(value)
        if size < rect.width - label_width then frame.put(painter, rect.x + rect.width - size, y, value, size) end
    end
    if rows < #items and rect.height >= 1 then
        frame.put(painter, rect.x, rect.y + rect.height - 1, "+" .. tostring(#items - rows) .. " more", rect.width, painter.theme.muted)
    end
end

local function column_bar(painter: frame.Painter, x: integer, bottom: integer, height: integer, width: integer, value: number, peak: number, fg: string)
    if M.is_gap(value) or peak <= 0 or height <= 0 then return end
    local eighths = clamp(round(value / peak * height * 8), 0, height * 8)
    if value > 0 and eighths == 0 then eighths = 1 end
    for row = 0, height - 1 do
        local level = eighths - row * 8
        if level > 0 then frame.clip(painter, x, bottom - row, string.rep(EIGHTHS_UP[minimum(8, level)], width), width, fg) end
    end
end

-- Vertical columns, one per item, growing from the row above the labels in
-- eighth blocks. Column width is the widest label up to 6 cells; items that do
-- not fit are not drawn.
function M.columns(painter: frame.Painter, rect: Rect, items: {Bar}, options: Scale?)
    if rect.width <= 0 or rect.height < 2 or #items == 0 then return end
    local scale: Scale = options or {}
    local peak = scale.max or 0
    local widest = 1
    for _, item in ipairs(items) do
        if not scale.max and not M.is_gap(item.value) and item.value > peak then peak = item.value end
        widest = maximum(widest, tty.text.width(item.label))
    end
    local width = clamp(widest, 1, 6)
    width = maximum(1, minimum(width, (rect.width + 1) // #items - 1))
    local bottom = rect.y + rect.height - 2
    for index, item in ipairs(items) do
        local x = rect.x + (index - 1) * (width + 1)
        if x + width - 1 > rect.x + rect.width - 1 then break end
        local role = item.role or status_role(item.value, scale.warn, scale.error, "accent")
        column_bar(painter, x, bottom, rect.height - 1, width, item.value, peak, color(painter, role, "accent"))
        frame.clip(painter, x, rect.y + rect.height - 1, item.label, width, painter.theme.muted)
    end
end

-- Stacked horizontal bars: a legend of names on the first row, then one row
-- per stack with its label, segments in the legend's glyphs and roles scaled
-- to max (default the largest total) and the total right-aligned.
function M.stacked(painter: frame.Painter, rect: Rect, stacks: {Stack}, names: {string}, options: Scale?)
    if rect.width <= 0 or rect.height <= 0 then return end
    local scale: Scale = options or {}
    local keys: {Key} = {}
    for index, name in ipairs(names) do keys[index] = {label = name, role = STACK_ROLES[(index - 1) % #STACK_ROLES + 1]} end
    M.legend(painter, rect.x, rect.y, rect.width, keys)
    local peak = scale.max or 0
    local label_width, value_width = 0, 0
    local totals: {number} = {}
    for index, stack in ipairs(stacks) do
        local total = 0
        for _, value in ipairs(stack.segments) do if not M.is_gap(value) then total = total + value end end
        totals[index] = total
        if not scale.max and total > peak then peak = total end
        label_width = maximum(label_width, tty.text.width(stack.label))
        value_width = maximum(value_width, tty.text.width(M.number(total, scale.unit)))
    end
    label_width = minimum(minimum(label_width, maximum(4, rect.width // 3)), rect.width)
    local bar_width = rect.width - label_width - value_width - 4
    for index, stack in ipairs(stacks) do
        local y = rect.y + index
        if y > rect.y + rect.height - 1 then break end
        frame.put(painter, rect.x, y, stack.label, label_width)
        if bar_width > 0 and peak > 0 then
            local running = 0
            local drawn = 0
            for segment, value in ipairs(stack.segments) do
                if not M.is_gap(value) then running = running + value end
                local finish = clamp(round(running / peak * bar_width), 0, bar_width)
                if finish > drawn then
                    local glyph = SHADES[(segment - 1) % #SHADES + 1]
                    frame.clip(painter, rect.x + label_width + 2 + drawn, y, string.rep(glyph, finish - drawn), finish - drawn,
                        color(painter, STACK_ROLES[(segment - 1) % #STACK_ROLES + 1], "accent"))
                    drawn = finish
                end
            end
        end
        local total = M.number(totals[index], scale.unit)
        local size = tty.text.width(total)
        if size < rect.width - label_width then frame.put(painter, rect.x + rect.width - size, y, total, size) end
    end
end

-- Counts of values in count equal bins from min to max (default the sample
-- range); gaps are skipped and the maximum falls in the last bin.
function M.bins(values: {number}, count: integer, min: number?, max: number?): {integer}
    local low, high = M.extent(values, min, max)
    if min == nil then
        local smallest: number? = nil
        for _, value in ipairs(values) do
            if not M.is_gap(value) and (smallest == nil or value < smallest) then smallest = value end
        end
        if smallest ~= nil and smallest < high then low = smallest end
    end
    local result: {integer} = {}
    local size = maximum(1, count)
    for index = 1, size do result[index] = 0 end
    for _, value in ipairs(values) do
        if not M.is_gap(value) and value >= low and value <= high then
            local bin = clamp(math.floor((value - low) / (high - low) * size) + 1, 1, size)
            result[bin] = result[bin] + 1
        end
    end
    return result
end

-- A histogram of values in count bins: adjacent columns in eighth blocks and
-- the range labels under the first and last bins.
function M.histogram(painter: frame.Painter, rect: Rect, values: {number}, count: integer, options: Chart?)
    if rect.width <= 0 or rect.height < 2 then return end
    local chart: Chart = options or {}
    local counts = M.bins(values, count, chart.min, chart.max)
    local low, high = M.extent(values, chart.min, chart.max)
    if chart.min == nil then
        local smallest: number? = nil
        for _, value in ipairs(values) do
            if not M.is_gap(value) and (smallest == nil or value < smallest) then smallest = value end
        end
        if smallest ~= nil and smallest < high then low = smallest end
    end
    local peak = 0
    for _, value in ipairs(counts) do if value > peak then peak = value end end
    local width = maximum(1, rect.width // maximum(1, #counts))
    local bottom = rect.y + rect.height - 2
    local fg = color(painter, nil, "accent")
    for index, value in ipairs(counts) do
        local x = rect.x + (index - 1) * width
        if x + width - 1 > rect.x + rect.width - 1 then break end
        column_bar(painter, x, bottom, rect.height - 1, width, value, peak, fg)
    end
    local left = M.number(low, chart.unit)
    local right = M.number(high, chart.unit)
    local used = minimum(rect.width, width * #counts)
    frame.put(painter, rect.x, rect.y + rect.height - 1, left, used, painter.theme.muted)
    local size = tty.text.width(right)
    if size + tty.text.width(left) + 1 <= used then
        frame.put(painter, rect.x + used - size, rect.y + rect.height - 1, right, size, painter.theme.muted)
    end
end

-- A heatmap: each value one cell (two when room) in the ramp ░▒▓█ of role
-- (default accent) scaled to max, zero as a muted "·", a gap blank; row labels
-- at the left and the first and last column labels under the grid.
function M.heatmap(painter: frame.Painter, rect: Rect, grid: Grid)
    if rect.width <= 0 or rect.height <= 0 then return end
    local peak = grid.max or 0
    local columns = 0
    for _, row in ipairs(grid.rows) do
        columns = maximum(columns, #row)
        if not grid.max then for _, value in ipairs(row) do if not M.is_gap(value) and value > peak then peak = value end end end
    end
    local label_width = 0
    for _, label in ipairs(grid.row_labels or {}) do label_width = maximum(label_width, tty.text.width(label)) end
    label_width = minimum(label_width, rect.width // 3)
    local x0 = rect.x + (label_width > 0 and label_width + 1 or 0)
    local room = rect.x + rect.width - x0
    local cell = (columns > 0 and room >= columns * 2) and 2 or 1
    local labelled = grid.column_labels ~= nil and #(grid.column_labels or {}) > 0
    local rows = minimum(#grid.rows, rect.height - (labelled and 1 or 0))
    local fg = color(painter, grid.role, "accent")
    for index = 1, rows do
        local y = rect.y + index - 1
        local labels = grid.row_labels or {}
        if label_width > 0 then frame.put(painter, rect.x, y, labels[index] or "", label_width, painter.theme.muted) end
        for column, value in ipairs(grid.rows[index]) do
            local x = x0 + (column - 1) * cell
            if x + cell - 1 > rect.x + rect.width - 1 then break end
            if not M.is_gap(value) then
                if value <= 0 or peak <= 0 then frame.clip(painter, x, y, "·", 1, painter.theme.muted)
                else
                    local level = clamp(math.ceil(value / peak * #RAMP), 1, #RAMP)
                    frame.clip(painter, x, y, string.rep(RAMP[level], cell), cell, fg)
                end
            end
        end
    end
    if labelled then
        local names = grid.column_labels or {}
        local y = rect.y + rows
        local used = minimum(room, columns * cell)
        frame.put(painter, x0, y, names[1] or "", used, painter.theme.muted)
        local last = names[#names] or ""
        local size = tty.text.width(last)
        if #names > 1 and size + tty.text.width(names[1] or "") + 1 <= used then
            frame.put(painter, x0 + used - size, y, last, size, painter.theme.muted)
        end
    end
end

-- A status grid of many items, two per cell with the half block ▀ (top item
-- in the foreground, bottom in the background), in reading order. Each state
-- is a role name (ok, warn, error, muted). Returns the number of items drawn;
-- write the counts in words beside it.
function M.waffle(painter: frame.Painter, rect: Rect, states: {string}): integer
    if rect.width <= 0 or rect.height <= 0 then return 0 end
    local columns = rect.width
    local capacity = columns * rect.height * 2
    local shown = minimum(#states, capacity)
    local theme = painter.theme
    for row = 0, rect.height - 1 do
        for column = 0, columns - 1 do
            local top = row * 2 * columns + column + 1
            local bottom = top + columns
            if top > shown then return shown end
            local fg = appearance.role(theme, states[top])
            local bg = bottom <= shown and appearance.role(theme, states[bottom]) or theme.surface
            frame.clip(painter, rect.x + column, rect.y + row, "▀", 1, fg, bg)
        end
    end
    return shown
end

local function meter(painter: frame.Painter, x: integer, y: integer, width: integer, fraction: number, text: string, label: string?, role: string)
    local column = x
    local limit = x + width
    if label and label ~= "" then
        column = column + frame.put(painter, column, y, label, maximum(0, width // 3), painter.theme.muted) + 1
    end
    local text_width = tty.text.width(text)
    local bar = limit - column - text_width - 1
    if bar >= 3 then
        local filled = clamp(round(fraction * bar), 0, bar)
        if filled > 0 then frame.clip(painter, column, y, string.rep("█", filled), filled, appearance.role(painter.theme, role)) end
        if bar - filled > 0 then frame.clip(painter, column + filled, y, string.rep("░", bar - filled), bar - filled, painter.theme.muted) end
        column = column + bar + 1
    end
    frame.put(painter, column, y, text, limit - column)
end

-- A capacity meter on row y: optional muted label, █ filled and ░ empty cells,
-- then the percentage. The fill takes warn or error at those thresholds
-- (fractions of max), accent otherwise.
function M.gauge(painter: frame.Painter, x: integer, y: integer, width: integer, value: number, max: number, options: Meter?)
    local meter_options: Meter = options or {}
    local fraction = (max > 0 and not M.is_gap(value)) and value / max or 0
    local text = M.is_gap(value) and "—" or (tostring(round(fraction * 100)) .. "%")
    meter(painter, x, y, width, fraction, text, meter_options.label,
        status_role(fraction, meter_options.warn, meter_options.error, "accent"))
end

-- Task progress on row y: the same bar with the exact "done/total" counts
-- after it; the fill is ok once done reaches total.
function M.progress(painter: frame.Painter, x: integer, y: integer, width: integer, done: number, total: number, options: Meter?)
    local meter_options: Meter = options or {}
    local fraction = total > 0 and done / total or 0
    local unit = meter_options.unit
    local text = M.count(done) .. "/" .. M.count(total) .. ((unit and unit ~= "") and (" " .. unit) or "")
    meter(painter, x, y, width, fraction, text, meter_options.label, (total > 0 and done >= total) and "ok" or "accent")
end

-- Stat tiles in a grid of equal cells at least min_width (default 18) wide:
-- the muted uppercase label and the value with its muted note on the next
-- row, and a sparkline of values on the third row when the rect has it.
-- Returns the number of tiles drawn.
function M.tiles(painter: frame.Painter, rect: Rect, tiles: {Tile}, min_width: integer?): integer
    if rect.width <= 0 or rect.height < 2 or #tiles == 0 then return 0 end
    local columns = clamp((rect.width + 2) // ((min_width or 18) + 2), 1, #tiles)
    local height = rect.height >= 3 and 3 or 2
    local rows = minimum((#tiles + columns - 1) // columns, (rect.height + 1) // (height + 1))
    local drawn = 0
    local cells = frame.grid({x = rect.x, y = rect.y, width = rect.width, height = rows * (height + 1) - 1}, columns, maximum(1, rows))
    for index, cell in ipairs(cells) do
        local tile = tiles[index]
        if not tile then break end
        frame.put(painter, cell.x, cell.y, string.upper(tile.label), cell.width, painter.theme.muted)
        local used = frame.put(painter, cell.x, cell.y + 1, tile.value, cell.width, color(painter, tile.role, "text"))
        if tile.note and tile.note ~= "" and used + 2 < cell.width then
            frame.put(painter, cell.x + used + 1, cell.y + 1, tile.note, cell.width - used - 1, painter.theme.muted)
        end
        if height == 3 and tile.values and cell.height >= 3 then
            M.sparkline(painter, cell.x, cell.y + 2, cell.width, tile.values or {})
        end
        drawn = drawn + 1
    end
    return drawn
end

-- A timeline: one lane per row with its muted label, each span as █ cells in
-- its role (default accent) between from and to (at least one cell), an
-- optional muted "│" at now, and the from and to labels on the last row.
function M.timeline(painter: frame.Painter, rect: Rect, lanes: {Lane}, window: Window)
    if rect.width <= 0 or rect.height < 2 then return end
    local label_width = 0
    for _, lane in ipairs(lanes) do label_width = maximum(label_width, tty.text.width(lane.label)) end
    label_width = minimum(label_width, rect.width // 3)
    local x0 = rect.x + (label_width > 0 and label_width + 2 or 0)
    local track = rect.x + rect.width - x0
    if track <= 0 then return end
    local span = window.to - window.from
    if span <= 0 then span = 1 end
    local function column(time: number): integer
        return clamp(math.floor((time - window.from) / span * track), 0, track - 1)
    end
    local rows = minimum(#lanes, rect.height - 1)
    for index = 1, rows do
        local lane = lanes[index]
        local y = rect.y + index - 1
        if label_width > 0 then frame.put(painter, rect.x, y, lane.label, label_width, painter.theme.muted) end
        if window.now and window.now >= window.from and window.now <= window.to then
            frame.clip(painter, x0 + column(window.now), y, "│", 1, painter.theme.muted)
        end
        for _, item in ipairs(lane.spans) do
            if item.finish >= window.from and item.start <= window.to then
                local first = column(math.max(item.start, window.from))
                local last = maximum(first, column(math.min(item.finish, window.to)))
                frame.clip(painter, x0 + first, y, string.rep("█", last - first + 1), last - first + 1, color(painter, item.role, "accent"))
            end
        end
    end
    local y = rect.y + rows
    local from = window.from_label or ""
    local to = window.to_label or ""
    frame.put(painter, x0, y, from, track, painter.theme.muted)
    local size = tty.text.width(to)
    if size > 0 and size + tty.text.width(from) + 1 <= track then frame.put(painter, x0 + track - size, y, to, size, painter.theme.muted) end
end

local UP, DOWN, LEFT, RIGHT = 1, 2, 4, 8
-- Box-drawing joins indexed by their direction bits (UP 1, DOWN 2, LEFT 4, RIGHT 8).
local JOINS: {string} = {"│", "│", "│", "─", "┘", "┐", "┤", "─", "└", "┌", "├", "─", "┴", "┬", "┼"}

-- A small directed graph laid out in layers from left to right: a node's
-- layer is one past its furthest predecessor, nodes keep their input order
-- within a layer and are spread over the rect's rows, and each edge runs from
-- the right of its source to an arrow "▸" before its target along box-drawing
-- lines in the border role that never cross a node's text. Each node is
-- "● label" with the dot in its role (default accent) and an optional muted
-- note on the row below when the rows allow. Nodes record hits of kind "node"
-- with their index and id. Returns the number of nodes drawn.
function M.graph(painter: frame.Painter, rect: Rect, nodes: {Node}, edges: {Edge}): integer
    if rect.width <= 0 or rect.height <= 0 then return 0 end
    local count = minimum(#nodes, M.GRAPH_NODES)
    local index_of: {[string]: integer} = {}
    for index = 1, count do index_of[nodes[index].id] = index end
    local links: {{integer}} = {}
    for position, edge in ipairs(edges) do
        if position > M.GRAPH_EDGES then break end
        local from = index_of[edge.from]
        local to = index_of[edge.to]
        if from and to and from ~= to then links[#links + 1] = {from, to} end
    end
    local layer: {integer} = {}
    for index = 1, count do layer[index] = 1 end
    for _ = 1, count do
        local changed = false
        for _, link in ipairs(links) do
            local wanted = layer[link[1]] + 1
            if wanted > layer[link[2]] and wanted <= count then layer[link[2]] = wanted; changed = true end
        end
        if not changed then break end
    end
    local layers: {{integer}} = {}
    local deepest = 0
    for index = 1, count do
        deepest = maximum(deepest, layer[index])
        layers[layer[index]] = layers[layer[index]] or {}
        local members = layers[layer[index]]
        members[#members + 1] = index
    end
    local with_notes = false
    for index = 1, count do if nodes[index].note and nodes[index].note ~= "" then with_notes = true end end
    local tallest = 0
    for level = 1, deepest do tallest = maximum(tallest, #(layers[level] or {})) end
    local node_height = (with_notes and tallest * 3 - 1 <= rect.height) and 2 or 1
    local widths: {integer} = {}
    local total = 0
    for level = 1, deepest do
        local widest = 0
        for _, index in ipairs(layers[level] or {}) do
            widest = maximum(widest, 2 + tty.text.width(nodes[index].label))
            if node_height == 2 then widest = maximum(widest, 2 + tty.text.width(nodes[index].note or "")) end
        end
        widths[level] = widest
        total = total + widest
    end
    local gap = deepest > 1 and clamp((rect.width - total) // (deepest - 1), 4, 12) or 0
    local share = deepest > 0 and maximum(3, (rect.width - gap * (deepest - 1)) // deepest) or 0
    local crowded = total + gap * maximum(0, deepest - 1) > rect.width
    local xs: {integer} = {}
    local x = rect.x
    for level = 1, deepest do
        if crowded then widths[level] = minimum(widths[level], share) end
        xs[level] = x
        x = x + widths[level] + gap
    end
    local ys: {integer} = {}
    local drawn: {boolean} = {}
    for level = 1, deepest do
        local members = layers[level] or {}
        local slots = (rect.height + 1) // (node_height + 1)
        for position, index in ipairs(members) do
            if position <= slots and xs[level] + 2 <= rect.x + rect.width - 1 then
                local band = rect.height / minimum(#members, slots)
                ys[index] = rect.y + math.floor((position - 1) * band + (band - node_height) / 2)
                drawn[index] = true
            end
        end
    end
    local occupied: {[integer]: boolean} = {}
    local function cell(cx: integer, cy: integer): integer return cy * 4096 + cx end
    for index = 1, count do
        if drawn[index] then
            local level = layer[index]
            for offset = 0, widths[level] - 1 do
                occupied[cell(xs[level] + offset, ys[index])] = true
                if node_height == 2 then occupied[cell(xs[level] + offset, ys[index] + 1)] = true end
            end
        end
    end
    local joins: {[integer]: integer} = {}
    local arrows: {[integer]: boolean} = {}
    local function mark(cx: integer, cy: integer, bits: integer)
        if cx < rect.x or cx > rect.x + rect.width - 1 or cy < rect.y or cy > rect.y + rect.height - 1 then return end
        local key = cell(cx, cy)
        if occupied[key] then return end
        joins[key] = (joins[key] or 0) | bits
    end
    for _, link in ipairs(links) do
        local source = link[1]
        local target = link[2]
        if drawn[source] and drawn[target] and layer[target] > layer[source] then
            local sx = xs[layer[source]] + tty.text.width(frame.fit(nodes[source].label, widths[layer[source]] - 2)) + 3
            local tx = xs[layer[target]] - 2
            local trunk = xs[layer[source]] + widths[layer[source]] + gap // 2
            local sy = ys[source]
            local ty = ys[target]
            for cx = sx, trunk - 1 do mark(cx, sy, LEFT | RIGHT) end
            if sy == ty then mark(trunk, sy, LEFT | RIGHT)
            else
                mark(trunk, sy, LEFT | (ty > sy and DOWN or UP))
                local step = ty > sy and 1 or -1
                for cy = sy + step, ty - step, step do mark(trunk, cy, UP | DOWN) end
                mark(trunk, ty, RIGHT | (ty > sy and UP or DOWN))
            end
            for cx = trunk + 1, tx do mark(cx, ty, LEFT | RIGHT) end
            arrows[cell(tx + 1, ty)] = true
        end
    end
    local border = painter.theme.border
    for key, bits in pairs(joins) do
        frame.clip(painter, key % 4096, key // 4096, JOINS[bits] or "┼", 1, border)
    end
    for key in pairs(arrows) do
        if not occupied[key] then frame.clip(painter, key % 4096, key // 4096, "▸", 1, border) end
    end
    local shown = 0
    for index = 1, count do
        if drawn[index] then
            local node = nodes[index]
            local level = layer[index]
            local nx = xs[level]
            local ny = ys[index]
            frame.clip(painter, nx, ny, "●", 1, color(painter, node.role, "accent"))
            frame.put(painter, nx + 2, ny, node.label, widths[level] - 2)
            if node_height == 2 and node.note and node.note ~= "" then
                frame.put(painter, nx + 2, ny + 1, node.note or "", widths[level] - 2, painter.theme.muted)
            end
            frame.add_hit(painter, "node", index, node.id, nx, ny, widths[level], node_height)
            shown = shown + 1
        end
    end
    return shown
end

return M
