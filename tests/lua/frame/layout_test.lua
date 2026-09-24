-- MIT. The frame's layout rules: size classes at 80x24, 120x36 and 160x48,
-- the canonical anatomy rows, exact grid and split geometry, borderless
-- panels, form fields, wizard steps, and status roles every theme can show.
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
local function rect(value: frame.Rect): string
    return tostring(value.x) .. "," .. tostring(value.y) .. " " .. tostring(value.width) .. "x" .. tostring(value.height)
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
local function luminance(hex: string): number
    local total = 0
    for index, weight in ipairs({0.2126, 0.7152, 0.0722}) do
        local channel = (tonumber(hex:sub(index * 2, index * 2 + 1), 16) or 0) / 255
        if channel <= 0.03928 then channel = channel / 12.92 else channel = ((channel + 0.055) / 1.055) ^ 2.4 end
        total = total + weight * channel
    end
    return total
end
local function contrast(a: string, b: string): number
    local x, y = luminance(a), luminance(b)
    return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05)
end

local function define_tests()
    test.describe("Application layout", function()
        test.it("classifies sizes only at the three breakpoints", function()
            test.eq(frame.size(79, 24), "narrow")
            test.eq(frame.size(80, 23), "narrow")
            test.eq(frame.size(80, 24), "compact")
            test.eq(frame.size(200, 35), "compact")
            test.eq(frame.size(120, 36), "standard")
            test.eq(frame.size(159, 60), "standard")
            test.eq(frame.size(160, 48), "wide")
        end)
        test.it("places header, tabs, work, action bar and footer on fixed rows", function()
            local full = frame.layout(frame.new(80, 24, appearance.defaults()), true, true)
            test.eq(full.size, "compact")
            test.eq(full.tabs, 2)
            test.eq(rect(full.work), "2,4 78x19")
            test.eq(full.actions, 23)
            test.eq(full.footer, 24)
            local plain_layout = frame.layout(frame.new(120, 36, appearance.defaults()), false, false)
            test.eq(plain_layout.tabs, 0)
            test.eq(plain_layout.actions, 0)
            test.eq(rect(plain_layout.work), "2,3 118x33")
            local short = frame.layout(frame.new(40, 5, appearance.defaults()), true, true)
            test.eq(short.tabs, 0)
            test.eq(short.actions, 0)
            test.eq(rect(short.work), "2,2 38x3")
            local one = frame.layout(frame.new(10, 1, appearance.defaults()), true, true)
            test.eq(one.footer, 0)
            test.eq(one.work.height, 0)
        end)
        test.it("splits, stacks and grids with exact gaps and leftover cells first", function()
            local area: frame.Rect = {x = 2, y = 4, width = 78, height = 19}
            local parts = frame.split(area, {24, 0}, 2)
            test.eq(rect(parts[1]), "2,4 24x19")
            test.eq(rect(parts[2]), "28,4 52x19")
            local rows = frame.stack(area, {3, 0, 0})
            test.eq(rect(rows[1]), "2,4 78x3")
            test.eq(rect(rows[2]), "2,8 78x7")
            test.eq(rect(rows[3]), "2,16 78x7")
            local cells = frame.grid({x = 2, y = 4, width = 117, height = 31}, 3, 2)
            test.eq(#cells, 6)
            test.eq(rect(cells[1]), "2,4 38x15")
            test.eq(rect(cells[2]), "42,4 38x15")
            test.eq(rect(cells[3]), "82,4 37x15")
            test.eq(rect(cells[4]), "2,20 38x15")
            local tight = frame.split({x = 1, y = 1, width = 10, height = 1}, {8, 8}, 2)
            test.eq(rect(tight[2]), "11,1 0x1")
        end)
        test.it("titles a panel without a border and returns the area below it", function()
            local painter = frame.new(40, 6, appearance.defaults())
            local inner = frame.panel(painter, {x = 2, y = 2, width = 38, height = 4}, "Heap", "12.4 MiB")
            test.eq(rect(inner), "2,3 38x3")
            test.eq(text(painter)[2], " HEAP" .. string.rep(" ", 26) .. "12.4 MiB ")
            local theme = appearance.theme("honey")
            test.eq(style_at(frame.rows(painter)[2], "HEAP"), rgb(theme.muted) .. "/" .. rgb(theme.surface))
            test.eq(style_at(frame.rows(painter)[2], "12.4"), rgb(theme.text) .. "/" .. rgb(theme.surface))
        end)
        test.it("draws a form field with a muted label, a selected row and an inline error", function()
            local painter = frame.new(50, 4, appearance.defaults())
            frame.field(painter, 1, "Name", "billing", 8, false, 1)
            frame.field(painter, 2, "Port", "99999", 8, true, 2, "must be below 65536")
            local rows = text(painter)
            test.eq(rows[1], " Name      billing" .. string.rep(" ", 32))
            test.eq(rows[2]:sub(1, #"›"), "›")
            test.is_true(rows[2]:find("Port      99999 · must be below 65536", 1, true) ~= nil)
            local hit = frame.hit(painter.hits, 30, 2)
            test.eq(hit and (hit.kind .. ":" .. tostring(hit.index)) or "", "field:2")
            local theme = appearance.theme("honey")
            test.eq(style_at(frame.rows(painter)[2], "· must"), rgb(theme.error) .. "/" .. rgb(theme.accent))
            test.eq(style_at(frame.rows(painter)[1], "Name"), rgb(theme.muted) .. "/" .. rgb(theme.surface))
        end)
        test.it("shows wizard steps in full and folds them to the current step", function()
            local painter = frame.new(60, 2, appearance.defaults())
            frame.steps(painter, 1, {"Source", "Review", "Deliver"}, 2)
            test.eq(text(painter)[1], "  ✓ Source  ›  2 Review  ›  3 Deliver" .. string.rep(" ", 23))
            frame.steps(painter, 2, {"Source", "Review", "Deliver"}, 2)
            local narrow = frame.new(24, 1, appearance.defaults())
            frame.steps(narrow, 1, {"Source", "Review", "Deliver"}, 2)
            test.eq(text(narrow)[1], "  Step 2/3 Review       ")
            for _, row in ipairs(frame.rows(narrow)) do test.eq(tty.text.width(row), 24) end
        end)
        test.it("keeps a panel's empty state inside the panel", function()
            local painter = frame.new(40, 4, appearance.defaults())
            frame.put(painter, 2, 2, "LEFT", 4)
            frame.empty(painter, 2, "No samples yet", "R retry", {x = 22, y = 2, width = 18, height = 2})
            local rows = text(painter)
            test.eq(rows[2], " LEFT" .. string.rep(" ", 16) .. "No samples yet" .. string.rep(" ", 5))
            test.eq(rows[3], string.rep(" ", 21) .. "R retry" .. string.rep(" ", 12))
            local short = frame.new(40, 4, appearance.defaults())
            frame.empty(short, 2, "No samples yet", "R retry", {x = 22, y = 2, width = 18, height = 1})
            test.eq(text(short)[3], string.rep(" ", 40))
        end)
        test.it("gives every theme readable status roles and resolves roles by name", function()
            for _, theme in ipairs(appearance.themes()) do
                for _, name in ipairs({"ok", "warn", "error", "accent", "muted"}) do
                    local color = appearance.role(theme, name)
                    test.is_true(color:match("^#%x%x%x%x%x%x$") ~= nil)
                    local ratio = contrast(color, theme.surface)
                    test.eq(theme.id .. " " .. name .. (ratio >= 3 and " readable" or (" " .. tostring(ratio))), theme.id .. " " .. name .. " readable")
                end
                test.eq(appearance.role(theme, "unknown"), theme.text)
            end
            test.eq(appearance.mix("#000000", "#ffffff", 0), "#000000")
            test.eq(appearance.mix("#000000", "#ffffff", 1), "#ffffff")
            test.eq(appearance.mix("#000000", "#ff8000", 0.5), "#804000")
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
