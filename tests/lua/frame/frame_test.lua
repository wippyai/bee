-- MIT. The shared frame keeps every row at the canvas width, keeps the header
-- summary off the title, puts status and hints on one footer row, marks the
-- selected row without color and folds a narrow table into one summary line.
local test = require("test")
local tty = require("tty")
local frame = require("frame")
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
local function sized(painter: frame.Painter)
    local rows = frame.rows(painter)
    test.eq(#rows, painter.height)
    for _, row in ipairs(rows) do test.eq(tty.text.width(row), painter.width) end
    for _, hit in ipairs(painter.hits) do
        test.is_true(hit.x >= 1 and hit.y >= 1)
        test.is_true(hit.x + hit.width - 1 <= painter.width)
        test.is_true(hit.y + hit.height - 1 <= painter.height)
    end
end
local function rgb(hex: string): string
    return tostring(tonumber(hex:sub(2, 3), 16)) .. ";" .. tostring(tonumber(hex:sub(4, 5), 16)) .. ";" .. tostring(tonumber(hex:sub(6, 7), 16))
end
-- The foreground and background in effect where needle starts in a styled row.
type Cell = {fg: string, bg: string}
local function style_at(row: string, needle: string): Cell?
    local fg, bg = "", ""
    local position = 1
    while position <= #row do
        local first, last, codes = row:find("\27%[([0-9;]*)m", position)
        local plain_end = first and first - 1 or #row
        local found = row:sub(position, plain_end):find(needle, 1, true)
        if found then return {fg = fg, bg = bg} end
        if not first or not last or not codes then return nil end
        if codes == "" or codes == "0" then fg, bg = "", "" end
        local fg_code = codes:match("38;2;(%d+;%d+;%d+)")
        local bg_code = codes:match("48;2;(%d+;%d+;%d+)")
        if fg_code then fg = fg_code end
        if bg_code then bg = bg_code end
        position = last + 1
    end
    return nil
end
local function columns(): {frame.Column}
    return {{title = "Name", width = 0}, {title = "State", width = 10}, {title = "Steps", width = 7, align = "right"}}
end
local function cells(): {{string}}
    return {{"bee.host:main", "idle", "96"}, {"bee.applications:broker\27[2J", "running\r", "70"}, {"bee.session:main", "idle", "16"}}
end

local function define_tests()
    test.describe("Application frame", function()
        test.it("fits every responsive geometry and strips hostile text", function()
            for _, width in ipairs({1, 20, 40, 80, 120}) do
                for _, height in ipairs({1, 6, 12, 24}) do
                    local painter = frame.new(width, height, appearance.defaults())
                    frame.header(painter, "PROCESSES", "Live · 3 processes \27[31m")
                    frame.tabs(painter, 2, {{kind = "a", label = "Processes", short = "P"}, {kind = "b", label = "Services", short = "S"}}, "a")
                    frame.table(painter, 3, height - 2, {columns = columns(), cells = cells(), kind = "row", selected = 2, offset = 0})
                    frame.actions(painter, height - 1, {{kind = "stop", label = "Stop app", key = "Del", enabled = true, primary = true},
                        {kind = "sort", label = "Sort", enabled = false}})
                    frame.footer(painter, "Stopped \7", frame.hints({{key = "↑↓", verb = "select"}, {key = "Esc", verb = "close"}}))
                    sized(painter)
                    for _, row in ipairs(frame.rows(painter)) do
                        local rendered = plain(row)
                        test.is_nil(rendered:find("\27", 1, true))
                        test.is_nil(rendered:find("\r", 1, true))
                        test.is_nil(rendered:find("\7", 1, true))
                    end
                end
            end
        end)
        test.it("draws a form field after switching from tabs to a dialog", function()
            local painter = frame.new(160, 48, appearance.defaults())
            local layout = frame.layout(painter, false, true)
            frame.header(painter, "AUTO RESEARCH", "0 loops running")
            frame.field(painter, layout.work.y + 2, "Title", "▏", 16, true, 1, nil)
            frame.actions(painter, layout.actions, {{kind = "submit", key = "Enter", label = "Save and start", enabled = true, primary = true}})
            frame.footer(painter, "State a research goal", frame.hints({{key = "↑↓", verb = "field"}, {key = "Enter", verb = "save and start"}}))
            sized(painter)
            local hit = frame.hit(painter.hits, 4, layout.work.y + 2)
            test.eq(hit and hit.kind, "field")
        end)
        test.it("truncates the header summary before it reaches the title", function()
            local painter = frame.new(40, 3, appearance.defaults())
            frame.header(painter, "MODULES  CATALOG", "wippy/a-very-long-package-name-that-overflows")
            local row = text(painter)[1]
            test.eq(row:sub(1, 18), " MODULES  CATALOG ")
            test.is_true(row:find("…", 1, true) ~= nil)
            local narrow = frame.new(20, 3, appearance.defaults())
            frame.header(narrow, "MODULES  CATALOG", "Browse the Hub")
            test.eq(text(narrow)[1], " MODULES  CATALOG   ")
        end)
        test.it("draws the header summary in the muted role, not the accent", function()
            local painter = frame.new(60, 3, appearance.defaults())
            frame.header(painter, "HIVE MANAGER", "1 node · 1 ready")
            local theme = appearance.theme("honey")
            local cell = style_at(frame.rows(painter)[1], "1 node")
            test.not_nil(cell)
            test.eq(cell and cell.fg or "", rgb(theme.muted))
        end)
        test.it("keeps key hints beside a status when both fit and lets the status win otherwise", function()
            local hints = frame.hints({{key = "↑↓", verb = "select"}, {key = "Enter", verb = "open"}})
            test.eq(hints, "↑↓ select · Enter open")
            local wide = frame.new(80, 4, appearance.defaults())
            frame.footer(wide, "Saved count 2", hints)
            local row = text(wide)[4]
            test.eq(row:sub(1, 15), " Saved count 2 ")
            test.eq(row:sub(-(#hints + 1)), hints .. " ")
            local narrow = frame.new(24, 4, appearance.defaults())
            frame.footer(narrow, "Saved count 2", hints)
            test.eq(text(narrow)[4], " Saved count 2          ")
            local idle = frame.new(40, 4, appearance.defaults())
            frame.footer(idle, "", hints)
            test.eq(text(idle)[4]:sub(1, #hints + 1), " " .. hints)
        end)
        test.it("marks the selected row in column 1 and keeps its text", function()
            local painter = frame.new(60, 8, appearance.defaults())
            local window = frame.table(painter, 2, 7, {columns = columns(), cells = cells(), kind = "row", selected = 2, offset = 0})
            test.eq(window.capacity, 5)
            local rows = text(painter)
            test.is_true(rows[2]:find("NAME", 1, true) ~= nil and rows[2]:find("STATE", 1, true) ~= nil)
            test.eq(rows[3]:sub(1, 2), " b")
            test.eq(rows[4]:sub(1, #"›"), "›")
            test.is_true(rows[4]:find("bee.applications:broker", 1, true) ~= nil)
            local hit = frame.hit(painter.hits, 30, 4)
            test.not_nil(hit)
            test.eq(hit and hit.index or 0, 2)
        end)
        test.it("confines a table to its area beside another pane", function()
            local painter = frame.new(60, 8, appearance.defaults())
            frame.put(painter, 30, 4, "DETAIL PANE", 20)
            local window = frame.table(painter, 2, 7, {columns = columns(), cells = cells(), kind = "row", selected = 2, offset = 0,
                area = {x = 2, y = 2, width = 26, height = 6}})
            test.eq(window.capacity, 5)
            local rows = text(painter)
            for _, row in ipairs(rows) do test.eq(tty.text.width(row), 60) end
            test.eq(rows[4]:sub(1, #"›"), "›")
            test.is_true(rows[4]:find("DETAIL PANE", 1, true) ~= nil)
            test.is_true(rows[2]:find("NAME", 1, true) ~= nil)
            local inside = frame.hit(painter.hits, 20, 4)
            test.eq(inside and inside.index or 0, 2)
            test.is_nil(frame.hit(painter.hits, 40, 4))
            for _, hit in ipairs(painter.hits) do test.is_true(hit.x >= 1 and hit.x + hit.width - 1 <= 27) end
        end)
        test.it("aligns table columns and right-aligns numbers", function()
            local painter = frame.new(60, 6, appearance.defaults())
            frame.table(painter, 1, 5, {columns = columns(), cells = cells(), kind = "row", selected = 0, offset = 0})
            local rows = text(painter)
            local state_at = rows[1]:find("STATE", 1, true)
            test.eq(rows[2]:find("idle", 1, true), state_at)
            test.eq(rows[4]:find("idle", 1, true), state_at)
            test.eq(rows[2]:sub(-3), "96 ")
            test.eq(rows[4]:sub(-3), "16 ")
        end)
        test.it("folds a narrow table into a first cell and a dotted summary", function()
            local painter = frame.new(30, 6, appearance.defaults())
            frame.table(painter, 1, 5, {columns = columns(), cells = cells(), kind = "row", selected = 0, offset = 0})
            local rows = text(painter)
            test.eq(rows[1], " NAME · STATE · STEPS         ")
            test.eq(rows[2], " bee.host:main · idle · 96    ")
            test.is_true(rows[3]:find("…", 1, true) ~= nil)
        end)
        test.it("keeps the selection inside the list window", function()
            local window = frame.window(20, 5, 12, 0)
            test.eq(window.offset, 7)
            test.eq(frame.window(20, 5, 3, 10).offset, 2)
            test.eq(frame.window(3, 5, 0, 9).offset, 0)
            test.eq(frame.window(3, 0, 2, 0).capacity, 0)
        end)
        test.it("fills only the primary action and gives disabled buttons no target", function()
            local painter = frame.new(60, 3, appearance.defaults())
            local theme = appearance.theme("honey")
            frame.actions(painter, 2, {{kind = "open", label = "Open", enabled = true, primary = true},
                {kind = "refresh", label = "Refresh", key = "R", enabled = true}, {kind = "deny", label = "Deny", enabled = false}})
            local row = frame.rows(painter)[2]
            local open, refresh, deny = style_at(row, " Open "), style_at(row, " R Refresh "), style_at(row, " Deny ")
            test.eq(open and (open.fg .. "/" .. open.bg) or "", rgb(appearance.selection_text(theme)) .. "/" .. rgb(theme.accent))
            test.eq(refresh and (refresh.fg .. "/" .. refresh.bg) or "", rgb(theme.accent) .. "/" .. rgb(theme.surface))
            test.eq(deny and (deny.fg .. "/" .. deny.bg) or "", rgb(theme.muted) .. "/" .. rgb(theme.surface))
            local kinds: {string} = {}
            for _, hit in ipairs(painter.hits) do kinds[#kinds + 1] = hit.kind end
            test.eq(table.concat(kinds, ","), "open,refresh")
        end)
        test.it("clips decoration without an ellipsis and bounds it to the canvas", function()
            local painter = frame.new(10, 2, appearance.defaults())
            test.eq(frame.clip(painter, 3, 1, string.rep("─", 40), 20), 8)
            test.eq(text(painter)[1], "  ────────")
            test.eq(frame.put(painter, 3, 2, string.rep("x", 40), 20), 8)
            test.eq(text(painter)[2], "  xxxxxxx…")
        end)
        test.it("states what is empty and the next action", function()
            local painter = frame.new(50, 6, appearance.defaults())
            frame.empty(painter, 3, "No requests", "Requests from agents appear here · R refresh")
            local rows = text(painter)
            test.eq(rows[3]:sub(1, 13), " No requests ")
            test.is_true(rows[4]:find("R refresh", 1, true) ~= nil)
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
