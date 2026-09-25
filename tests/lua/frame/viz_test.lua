-- MIT. The visualization kit draws exact golden frames, stays inside the
-- rectangle it is given at every size, colors marks by semantic role and
-- keeps live series bounded. Each "-- example:" block below is the proven
-- example build/agent_corpus.py publishes for the named kit functions: its
-- code, its test.eq results and its golden frame as a screenshot.
local test = require("test")
local tty = require("tty")
local frame = require("frame")
local viz = require("viz")
local appearance = require("appearance")

local function plain(row: string): string
    local value = row:gsub("\27%[[0-9;]*m", "")
    return value
end
local function text(painter: frame.Painter): {string}
    local rows: {string} = {}
    for index, row in ipairs(frame.rows(painter)) do rows[index] = plain(row) end
    return rows
end
local function rgb(hex: string): string
    return tostring(tonumber(hex:sub(2, 3), 16)) .. ";" .. tostring(tonumber(hex:sub(4, 5), 16)) .. ";" .. tostring(tonumber(hex:sub(6, 7), 16))
end
-- The foreground and background in effect where needle starts in a styled row.
local function style_at(row: string, needle: string): string
    local fg, bg = "", ""
    local position = 1
    while position <= #row do
        local first, last, codes = row:find("\27%[([0-9;]*)m", position)
        local plain_end = first and first - 1 or #row
        if row:sub(position, plain_end):find(needle, 1, true) then return fg .. "/" .. bg end
        if not first or not last or not codes then return "" end
        if codes == "" or codes == "0" then fg, bg = "", "" end
        local fg_code = codes:match("38;2;(%d+;%d+;%d+)")
        local bg_code = codes:match("48;2;(%d+;%d+;%d+)")
        if fg_code then fg = fg_code end
        if bg_code then bg = bg_code end
        position = last + 1
    end
    return ""
end
-- The foreground and background of every occurrence of glyph in a styled row.
local function styles_of(row: string, glyph: string): {string}
    local found: {string} = {}
    local fg, bg = "", ""
    local position = 1
    while position <= #row do
        local first, last, codes = row:find("\27%[([0-9;]*)m", position)
        local plain_end = first and first - 1 or #row
        local segment = row:sub(position, plain_end)
        local at = 1
        while true do
            local hit = segment:find(glyph, at, true)
            if not hit then break end
            found[#found + 1] = fg .. "/" .. bg
            at = hit + #glyph
        end
        if not first or not last or not codes then break end
        if codes == "" or codes == "0" then fg, bg = "", "" end
        local fg_code = codes:match("38;2;(%d+;%d+;%d+)")
        local bg_code = codes:match("48;2;(%d+;%d+;%d+)")
        if fg_code then fg = fg_code end
        if bg_code then bg = bg_code end
        position = last + 1
    end
    return found
end
local function golden(painter: frame.Painter, expected: {string})
    local rows = text(painter)
    test.eq(#rows, #expected)
    for index, row in ipairs(expected) do test.eq(rows[index], row) end
end
local function wave(): {number}
    local values: {number} = {}
    for index = 1, 60 do values[index] = 50 + 40 * math.sin(index / 6) end
    return values
end
local function honey(): appearance.Theme return appearance.theme("honey") end

local SPARKLINE: {string} = {"           ▃▄▂▇▅█▄▆·▄▇█ "}
local TABLE_BARS: {string} = {
    " PROCESS                       STEPS              ",
    " bee.host:main                 ████████████    96 ",
    " bee.session:main              ██              16 ",
    " bee.apps:broker               ████████▊       70 "}
local LINE: {string} = {
    " 90 ms ┤  ⢀⡴⠚⠉⠙⠲⣄            ⢀⡴⠚⠉⠙⢦⡀    ",
    "       │ ⣠⠏     ⠘⢦⡀         ⣰⠋     ⠙⢦   ",
    "       │          ⠳⣄      ⢀⡞⠁       ⠈⠳⡄ ",
    "       │           ⠘⢦⡀  ⢀⡴⠋           ⠙ ",
    "  0 ms ┤             ⠉⠓⠒⠋               ",
    "       └─────────────────────────────── ",
    "        -60s                        now ",
    "                                        "}
local AREA: {string} = {
    " 100 ┤               ▂▃▄▅▅▅▄▃▂▁         ",
    "     │          ▁▃▅▇███████████▇▅▃▁     ",
    "     │      ▁▂▄▇███████████████████▇▅▃▁ ",
    "   0 ┤▃▃▄▄▆▇███████████████████████████ ",
    "     └───────────────────────────────── ",
    "                                        "}
local BARS: {string} = {
    " running  █████████████████████████  31 ",
    " idle     ████████▉                  11 ",
    " waiting  ██▍                         3 ",
    "                                        "}
local COLUMNS: {string} = {
    "     ███                      ",
    "     ███                      ",
    " ███ ███                      ",
    " ███ ███ ███                  ",
    " mon tue wed                  "}
local STACKED: {string} = {
    " █ busy  ▓ idle  ▒ failed               ",
    " node-a  ████████████████▓▓▓▓▓▓▓▒▒▒  10 ",
    " node-b  █████▓▓▓▓▓                   4 "}
local HISTOGRAM: {string} = {
    " ████████                     ",
    " ████████▅▅▅▅                 ",
    " ████████████▃▃▃▃        ▃▃▃▃ ",
    " ████████████████        ████ ",
    " 1 ms                    9 ms "}
local HEATMAP: {string} = {
    " mon · ░░▒▒▓▓██               ",
    " tue ██▓▓  ░░·                ",
    " wed ▒▒▒▒▒▒▒▒▒▒               ",
    "     00h    04h               "}
local WAFFLE: {string} = {
    " ▀▀▀▀▀▀▀▀▀▀ ",
    "            "}
local METERS: {string} = {
    " Heap ██████████████████░░░░░░░░░░░ 62% ",
    " █████████████████████░░░░░ 3,180/4,000 "}
local TILES: {string} = {
    " HEAP                GOROUTINES          GC                 ",
    " 12.4 MiB ▲0.8       214                 38                 ",
    "        ▃▄▂▇▅█▄▆▄▇█                                         "}
local TIMELINE: {string} = {
    " build  ███████████            │        ",
    " test             ████████████████      ",
    " ship                          │ ██████ ",
    "        18:00                     19:00 "}
local GRAPH: {string} = {
    "                                                            ",
    "              ┌────▸● node-a  ──────┐                       ",
    "              │       ready         │                       ",
    " ● hub  ──────┤                     └────▸● agent           ",
    "   owner      │                             managed         ",
    "              └────▸● node-b                                ",
    "                      degraded                              ",
    "                                                            ",
    "                                                            "}
local PIPELINE: {string} = {
    "                                                            ",
    " ● fetch ─────▸● classify ×12 ─────▸● dedupe ─────▸● report ",
    "                                                            "}
local LEGEND: {string} = {
    " █ heap  ▓ stack  ▒ free                "}

type Draw = (painter: frame.Painter, rect: frame.Rect) -> ()
local function drawings(): {Draw}
    local values = wave()
    local nodes: {viz.Node} = {{id = "hub", label = "hub", note = "owner"}, {id = "a", label = "node-a", role = "ok", note = "ready"},
        {id = "b", label = "node-b", role = "warn"}, {id = "c", label = "agent"}}
    local edges: {viz.Edge} = {{from = "hub", to = "a"}, {from = "hub", to = "b"}, {from = "a", to = "c"}, {from = "c", to = "hub"}}
    return {
        function(p: frame.Painter, r: frame.Rect) viz.sparkline(p, r.x, r.y, r.width, values) end,
        function(p: frame.Painter, r: frame.Rect) viz.line(p, r, {{values = values}, {values = {1, 2, 3}}}, {unit = "ms", from = "-60s", to = "now"}) end,
        function(p: frame.Painter, r: frame.Rect) viz.line(p, r, {{values = values}}, {area = true}) end,
        function(p: frame.Painter, r: frame.Rect) viz.bars(p, r, {{label = "running", value = 31}, {label = "idle", value = 11}, {label = "waiting", value = 3}}) end,
        function(p: frame.Painter, r: frame.Rect) viz.columns(p, r, {{label = "mon", value = 4}, {label = "tue", value = 8}, {label = "wed", value = 2}}) end,
        function(p: frame.Painter, r: frame.Rect) viz.stacked(p, r, {{label = "a", segments = {6, 3, 1}}}, {"busy", "idle", "failed"}) end,
        function(p: frame.Painter, r: frame.Rect) viz.histogram(p, r, values, 12) end,
        function(p: frame.Painter, r: frame.Rect) viz.heatmap(p, r, {rows = {{0, 1, 2}, {3, 4, 5}}, row_labels = {"mon", "tue"}, column_labels = {"00h", "08h"}}) end,
        function(p: frame.Painter, r: frame.Rect) viz.waffle(p, r, {"ok", "error", "warn", "ok", "ok", "muted", "ok"}) end,
        function(p: frame.Painter, r: frame.Rect) viz.gauge(p, r.x, r.y, r.width, 62, 100, {label = "Heap"}) end,
        function(p: frame.Painter, r: frame.Rect) viz.progress(p, r.x, r.y, r.width, 3180, 4000) end,
        function(p: frame.Painter, r: frame.Rect) viz.tiles(p, r, {{label = "Heap", value = "12.4 MiB", note = "▲0.8", values = values}, {label = "GC", value = "38"}}) end,
        function(p: frame.Painter, r: frame.Rect) viz.timeline(p, r, {{label = "build", spans = {{start = 0, finish = 20}}}}, {from = 0, to = 60, now = 30, from_label = "18:00", to_label = "19:00"}) end,
        function(p: frame.Painter, r: frame.Rect) viz.graph(p, r, nodes, edges) end,
        function(p: frame.Painter, r: frame.Rect) viz.legend(p, r.x, r.y, r.width, {{label = "heap"}, {label = "stack"}}) end,
    }
end

local function define_tests()
    test.describe("Visualization kit", function()
        test.it("keeps a live series bounded and ordered oldest first", function()
            -- example: series, push, values, latest, is_gap
            local series = viz.series(3)
            test.is_nil(viz.latest(series))
            for value = 1, 5 do viz.push(series, value) end
            test.eq(table.concat(viz.values(series), ","), "3,4,5")
            test.eq(viz.latest(series), 5)
            test.eq(series.total, 5)
            test.eq(#series.items, 3)
            for value = 6, 1000 do viz.push(series, value) end
            test.eq(#series.items, 3)
            test.eq(table.concat(viz.values(series), ","), "998,999,1000")
            viz.push(series, viz.GAP)
            test.eq(viz.is_gap(viz.latest(series) or 0), true)
        end)
        test.it("draws at most one frame per cadence interval", function()
            -- example: cadence, due
            local cadence = viz.cadence(1000)
            test.eq(viz.due(cadence, 5000), true)
            test.eq(viz.due(cadence, 5400), false)
            test.eq(viz.due(cadence, 6000), true)
            test.eq(viz.due(cadence, 6999), false)
            test.eq(viz.due(cadence, 7100), true)
            test.eq(cadence.next_at, 8000)
            test.eq(viz.due(cadence, 12345), true)
            test.eq(cadence.next_at, 13345)
        end)
        test.it("formats compact numbers, bytes and exact counts", function()
            -- example: number, bytes, count, extent
            test.eq(viz.number(7), "7")
            test.eq(viz.number(7.26), "7.3")
            test.eq(viz.number(42.4, "ms"), "42 ms")
            test.eq(viz.number(1234), "1.2k")
            test.eq(viz.number(12345), "12k")
            test.eq(viz.number(999999), "1M")
            test.eq(viz.number(3400000), "3.4M")
            test.eq(viz.number(viz.GAP), "—")
            test.eq(viz.bytes(512), "512 B")
            test.eq(viz.bytes(13002342), "12.4 MiB")
            test.eq(viz.count(4000), "4,000")
            test.eq(viz.count(1234567), "1,234,567")
            test.eq(viz.count(12), "12")
            local low, high = viz.extent({4, 9, viz.GAP, 6})
            test.eq(tostring(low) .. ".." .. tostring(high), "0..9")
            local flat_low, flat_high = viz.extent({5, 5}, 5)
            test.eq(tostring(flat_low) .. ".." .. tostring(flat_high), "5..6")
        end)
        test.it("draws a sparkline from zero with gaps and right alignment", function()
            -- example: spark
            test.eq(viz.spark({0, 2, 4, 8}, 6), "  ▁▂▄█")
            test.eq(viz.spark({1, viz.GAP, 3}, 3), "▃·█")
            test.eq(viz.spark({5, 5, 5}, 2), "██")
            test.eq(viz.spark({1, 2, 3, 4, 5, 6, 7, 8, 9, 10}, 4), "▆▇██")
            test.eq(viz.spark({4, 6}, 2, 4, 6), "▁█")
            test.eq(viz.spark({1}, 0), "")

            -- example: sparkline
            local painter = frame.new(24, 1, appearance.defaults())
            viz.sparkline(painter, 2, 1, 22, {3, 5, 2, 8, 6, 9, 4, 7, viz.GAP, 5, 8, 10})
            golden(painter, SPARKLINE)
        end)
        test.it("sizes inline bars in eighths and bins values", function()
            -- example: bar_cell
            test.eq(viz.bar_cell(5, 10, 4), "██  ")
            test.eq(viz.bar_cell(3, 8, 4), "█▌  ")
            test.eq(viz.bar_cell(20, 10, 3), "███")
            test.eq(viz.bar_cell(viz.GAP, 10, 2), "  ")
            local rows = frame.new(50, 4, appearance.defaults())
            frame.table(rows, 1, 4, {columns = {{title = "Process", width = 0}, {title = "Steps", width = 12}, {title = "", width = 4, align = "right"}},
                cells = {{"bee.host:main", viz.bar_cell(96, 96, 12), "96"}, {"bee.session:main", viz.bar_cell(16, 96, 12), "16"},
                    {"bee.apps:broker", viz.bar_cell(70, 96, 12), "70"}}, kind = "row", selected = 0, offset = 0})
            golden(rows, TABLE_BARS)

            -- example: bins
            test.eq(table.concat(viz.bins({1, 2, 2, 3, 9, viz.GAP}, 4), ","), "3,1,0,1")
            test.eq(table.concat(viz.bins({0, 5, 10}, 2, 0, 10), ","), "1,2")
        end)
        test.it("draws line and area charts with axis labels", function()
            -- example: line
            local values: {number} = {}
            for index = 1, 60 do values[index] = 50 + 40 * math.sin(index / 6) end
            local line = frame.new(40, 8, appearance.defaults())
            viz.line(line, {x = 2, y = 1, width = 38, height = 7}, {{values = values}}, {unit = "ms", from = "-60s", to = "now"})
            golden(line, LINE)

            test.eq(style_at(frame.rows(line)[1], "⢀⡴"), rgb(honey().accent) .. "/" .. rgb(honey().surface))
            test.eq(style_at(frame.rows(line)[1], "90 ms"), rgb(honey().muted) .. "/" .. rgb(honey().surface))

            -- example: line
            local area = frame.new(40, 6, appearance.defaults())
            viz.line(area, {x = 2, y = 1, width = 38, height = 5}, {{values = values}}, {area = true, min = 0, max = 100})
            golden(area, AREA)
        end)
        test.it("draws bars, columns, stacked bars and a histogram", function()

            -- example: bars
            local bars = frame.new(40, 4, appearance.defaults())
            viz.bars(bars, {x = 2, y = 1, width = 38, height = 4}, {{label = "running", value = 31}, {label = "idle", value = 11}, {label = "waiting", value = 3}})
            golden(bars, BARS)

            -- example: columns
            local columns = frame.new(30, 5, appearance.defaults())
            viz.columns(columns, {x = 2, y = 1, width = 28, height = 5}, {{label = "mon", value = 4}, {label = "tue", value = 8}, {label = "wed", value = 2}})
            golden(columns, COLUMNS)

            -- example: stacked
            local stacked = frame.new(40, 3, appearance.defaults())
            viz.stacked(stacked, {x = 2, y = 1, width = 38, height = 3}, {{label = "node-a", segments = {6, 3, 1}}, {label = "node-b", segments = {2, 2, 0}}}, {"busy", "idle", "failed"})
            golden(stacked, STACKED)

            -- example: histogram
            local histogram = frame.new(30, 5, appearance.defaults())
            viz.histogram(histogram, {x = 2, y = 1, width = 28, height = 5}, {1, 2, 2, 3, 3, 3, 4, 4, 5, 9}, 7, {unit = "ms"})
            golden(histogram, HISTOGRAM)
        end)
        test.it("gives bars past a declared threshold the status role and keeps the value", function()
            local painter = frame.new(40, 3, appearance.defaults())
            viz.bars(painter, {x = 2, y = 1, width = 38, height = 3}, {{label = "cpu", value = 95}, {label = "disk", value = 75}, {label = "net", value = 10}},
                {max = 100, warn = 70, error = 90})
            local rows = frame.rows(painter)
            local theme = honey()
            test.eq(style_at(rows[1], "█"), rgb(theme.error) .. "/" .. rgb(theme.surface))
            test.eq(style_at(rows[2], "█"), rgb(theme.warn) .. "/" .. rgb(theme.surface))
            test.eq(style_at(rows[3], "█"), rgb(theme.accent) .. "/" .. rgb(theme.surface))
            test.is_true(plain(rows[1]):find("95", 1, true) ~= nil)
            local folded = frame.new(30, 2, appearance.defaults())
            viz.bars(folded, {x = 2, y = 1, width = 28, height = 2}, {{label = "a", value = 1}, {label = "b", value = 2}, {label = "c", value = 3}})
            test.eq(text(folded)[2], " +2 more" .. string.rep(" ", 22))
        end)
        test.it("draws a heatmap and a two-per-cell status grid", function()
            -- example: heatmap
            local heatmap = frame.new(30, 4, appearance.defaults())
            viz.heatmap(heatmap, {x = 2, y = 1, width = 28, height = 4}, {rows = {{0, 1, 2, 3, 4}, {4, 3, 0 / 0, 1, 0}, {2, 2, 2, 2, 2}},
                row_labels = {"mon", "tue", "wed"}, column_labels = {"00h", "04h"}})
            golden(heatmap, HEATMAP)

            -- example: waffle
            local waffle = frame.new(12, 2, appearance.defaults())
            local shown = viz.waffle(waffle, {x = 2, y = 1, width = 10, height = 2}, {"ok", "ok", "error", "ok", "ok", "ok", "ok", "ok", "ok", "ok", "ok", "warn"})
            test.eq(shown, 12)
            golden(waffle, WAFFLE)

            local cells = styles_of(frame.rows(waffle)[1], "▀")
            local theme = honey()
            test.eq(#cells, 10)
            test.eq(cells[1], rgb(theme.ok) .. "/" .. rgb(theme.ok))
            test.eq(cells[2], rgb(theme.ok) .. "/" .. rgb(theme.warn))
            test.eq(cells[3], rgb(theme.error) .. "/" .. rgb(theme.surface))
        end)
        test.it("draws a gauge with thresholds and exact progress counts", function()
            -- example: gauge, progress
            local meters = frame.new(40, 2, appearance.defaults())
            viz.gauge(meters, 2, 1, 38, 62, 100, {label = "Heap"})
            viz.progress(meters, 2, 2, 38, 3180, 4000)
            golden(meters, METERS)

            local hot = frame.new(30, 2, appearance.defaults())
            viz.gauge(hot, 2, 1, 28, 0.93, 1, {warn = 0.7, error = 0.9})
            viz.progress(hot, 2, 2, 28, 4, 4)
            local theme = honey()
            test.eq(style_at(frame.rows(hot)[1], "█"), rgb(theme.error) .. "/" .. rgb(theme.surface))
            test.is_true(text(hot)[1]:find("93%", 1, true) ~= nil)
            test.eq(style_at(frame.rows(hot)[2], "█"), rgb(theme.ok) .. "/" .. rgb(theme.surface))
            test.eq(style_at(frame.rows(hot)[2], "░"), "")
        end)
        test.it("draws stat tiles, a timeline and a legend", function()
            -- example: tiles
            local tiles = frame.new(60, 3, appearance.defaults())
            test.eq(viz.tiles(tiles, {x = 2, y = 1, width = 58, height = 3}, {{label = "Heap", value = "12.4 MiB", note = "▲0.8", values = {3, 5, 2, 8, 6, 9, 4, 7, 5, 8, 10}},
                {label = "Goroutines", value = "214"}, {label = "GC", value = "38"}}), 3)
            golden(tiles, TILES)

            -- example: timeline
            local timeline = frame.new(40, 4, appearance.defaults())
            viz.timeline(timeline, {x = 2, y = 1, width = 38, height = 4}, {{label = "build", spans = {{start = 0, finish = 20}}},
                {label = "test", spans = {{start = 20, finish = 50, role = "ok"}}}, {label = "ship", spans = {{start = 50, finish = 60}}}},
                {from = 0, to = 60, now = 45, from_label = "18:00", to_label = "19:00"})
            golden(timeline, TIMELINE)
            test.eq(style_at(frame.rows(timeline)[2], "█"), rgb(honey().ok) .. "/" .. rgb(honey().surface))

            -- example: legend
            local legend = frame.new(40, 1, appearance.defaults())
            viz.legend(legend, 2, 1, 38, {{label = "heap"}, {label = "stack"}, {label = "free"}})
            golden(legend, LEGEND)
        end)
        test.it("lays out a small topology and a pipeline with routed edges and node targets", function()
            -- example: graph
            local graph = frame.new(60, 9, appearance.defaults())
            test.eq(viz.graph(graph, {x = 2, y = 1, width = 58, height = 9}, {{id = "hub", label = "hub", note = "owner"},
                {id = "a", label = "node-a", role = "ok", note = "ready"}, {id = "b", label = "node-b", role = "warn", note = "degraded"},
                {id = "c", label = "agent", note = "managed"}}, {{from = "hub", to = "a"}, {from = "hub", to = "b"}, {from = "a", to = "c"}}), 4)
            golden(graph, GRAPH)

            local rows = frame.rows(graph)
            local theme = honey()
            test.eq(style_at(rows[4], "┤"), rgb(theme.border) .. "/" .. rgb(theme.surface))
            test.eq(style_at(rows[2], "●"), rgb(theme.ok) .. "/" .. rgb(theme.surface))
            local hit = frame.hit(graph.hits, 23, 2)
            test.eq(hit and (hit.kind .. ":" .. hit.key) or "", "node:a")
            -- example: graph
            local pipeline = frame.new(60, 3, appearance.defaults())
            viz.graph(pipeline, {x = 2, y = 1, width = 58, height = 3}, {{id = "f", label = "fetch"}, {id = "c", label = "classify ×12"},
                {id = "d", label = "dedupe"}, {id = "r", label = "report"}}, {{from = "f", to = "c"}, {from = "c", to = "d"}, {from = "d", to = "r"}})
            golden(pipeline, PIPELINE)

            local cycle = frame.new(40, 5, appearance.defaults())
            test.eq(viz.graph(cycle, {x = 2, y = 1, width = 38, height = 5}, {{id = "a", label = "a"}, {id = "b", label = "b"}},
                {{from = "a", to = "b"}, {from = "b", to = "a"}}), 2)
        end)
        test.it("draws only inside its rectangle at every size and keeps rows at the canvas width", function()
            for number, draw in ipairs(drawings()) do
                for _, size in ipairs({{0, 0}, {1, 1}, {3, 2}, {8, 3}, {20, 4}, {38, 9}, {78, 19}}) do
                    local painter = frame.new(size[1] + 4, size[2] + 4, appearance.defaults())
                    local rect: frame.Rect = {x = 3, y = 3, width = size[1], height = size[2]}
                    draw(painter, rect)
                    local rows = text(painter)
                    test.eq(#rows, size[2] + 4)
                    local label = "drawing " .. tostring(number) .. " at " .. tostring(size[1]) .. "x" .. tostring(size[2]) .. ": "
                    for y, row in ipairs(frame.rows(painter)) do
                        test.eq(tty.text.width(row), size[1] + 4)
                        local clean = rows[y]
                        if y < 3 or y > 2 + size[2] then test.eq(label .. clean, label .. string.rep(" ", size[1] + 4))
                        else
                            test.eq(label .. tty.text.truncate(clean, 2, ""), label .. "  ")
                            test.eq(label .. tty.text.cut(clean, size[1] + 2, size[1] + 4), label .. "  ")
                        end
                    end
                    for _, hit in ipairs(painter.hits) do
                        test.is_true(hit.x >= 3 and hit.y >= 3 and hit.x + hit.width - 1 <= 2 + size[1] and hit.y + hit.height - 1 <= 2 + size[2])
                    end
                end
            end
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
