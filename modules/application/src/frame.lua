-- MIT. The shared application frame: one header, tabs, an action bar, one
-- status and key-hint footer, a scrolling list, a table and an empty or error
-- state, all drawn from semantic appearance roles. Pure: it paints one canvas
-- and records hit rectangles; it performs no calls and grants nothing.
--
-- Anatomy, top to bottom: row 1 header, optional tabs, work, the action bar on
-- the penultimate row and the footer (status, then key hints) on the final row.
local tty = require("tty")
local appearance = require("appearance")
local M = {}
local RESET = "\27[0m"
local ELLIPSIS = "…"
local MARKER = "›"

type Hit = {kind: string, index: integer, key: string, x: integer, y: integer, width: integer, height: integer}
-- A button with a key is drawn as "Key Label"; primary marks the one filled
-- action, active a selected toggle. Disabled buttons stay visible and have no hit.
type Button = {kind: string, label: string, enabled: boolean, primary: boolean?, active: boolean?, key: string?}
type Tab = {kind: string, label: string, short: string?}
type Hint = {key: string, verb: string}
type Controls = {buttons: {Button}, overflow: {Button}, hints: {Hint}, status: string?}
type Bar = {x: integer, buttons: {Button}}
type Painter = {width: integer, height: integer, theme: appearance.Theme, canvas: tty.Canvas, hits: {Hit}, controls: Controls, bars: {[integer]: Bar}}
type View = {rows: {string}, hits: {Hit}, controls: Controls?}
type Menu = {mode: string, selected: integer, offset: integer, controls: Controls, hits: {Hit}, signature: string, count: integer}

type Window = {offset: integer, capacity: integer}
-- A table column: width 0 is the single flexible column; align "right" for numbers.
type Column = {title: string, width: integer, align: string?}
-- A cell rectangle: x and y are one-based, width and height may be zero.
type Rect = {x: integer, y: integer, width: integer, height: integer}
-- area confines the table to a region's columns, as the list pane beside a
-- detail pane; its rows then span only that region and its marker column.
type Table = {columns: {Column}, cells: {{string}}, keys: {string}?, kind: string, selected: integer, offset: integer, focused: boolean?,
    area: Rect?}
-- The rows of the canonical anatomy; tabs and actions are 0 when absent.
type Layout = {size: string, tabs: integer, work: Rect, actions: integer, footer: integer}
-- One flattened, already-filtered tree row; the caller walks the tree and
-- owns which nodes are expanded. On a tree, an inspector or a log view, area
-- confines the rows to a region's columns, as it does on a table.
type TreeRow = {label: string, depth: integer, expandable: boolean?, expanded: boolean?, role: string?, key: string?}
type TreeView = {rows: {TreeRow}, selected: integer, offset: integer, focused: boolean?, area: Rect?}
-- One key-value inspector row.
type Entry = {label: string, value: string, role: string?}
type Inspector = {entries: {Entry}, selected: integer, offset: integer, label_width: integer?, focused: boolean?, area: Rect?}
-- One log line; role colors it (default text).
type LogLine = {text: string, role: string?}
type LogView = {lines: {LogLine}, selected: integer, offset: integer, query: string?, focused: boolean?, area: Rect?}
-- One toast notification, drawn in role's color (default accent).
type Toast = {text: string, role: string?}
-- One command palette choice.
type Choice = {label: string, key: string?, note: string?}
type Palette = {query: string, choices: {Choice}, selected: integer, offset: integer}

local function maximum(a: integer, b: integer): integer if a > b then return a end; return b end
local function minimum(a: integer, b: integer): integer if a < b then return a end; return b end

-- Replaces control characters and truncates to a display width with an ellipsis.
function M.fit(value: string, room: integer): string
    if room <= 0 then return "" end
    local clean = value:gsub("[%z\1-\31\127]", " ")
    return tty.text.truncate(clean, room, ELLIPSIS)
end

-- Pads a fitted value to exactly room cells, aligned left or right.
function M.pad(value: string, room: integer, align: string?): string
    local fitted = M.fit(value, room)
    local gap = string.rep(" ", maximum(0, room - tty.text.width(fitted)))
    if align == "right" then return gap .. fitted end
    return fitted .. gap
end

-- A painter over a canvas cleared to the theme's surface, with no hits yet.
function M.new(width: integer, height: integer, preferences: appearance.Preferences): Painter
    local theme = appearance.theme(preferences.theme)
    local canvas = tty.canvas(width, height)
    canvas:clear(appearance.style(theme.text, theme.surface) .. " " .. RESET)
    local controls: Controls = {buttons = {}, overflow = {}, hints = {}, status = ""}
    local bars: {[integer]: Bar} = {}
    return {width = width, height = height, theme = theme, canvas = canvas, hits = {}, controls = controls, bars = bars}
end

-- The painted rows, ready for output:present.
function M.rows(painter: Painter): {string}
    for y, bar in pairs(painter.bars) do M.actions(painter, y, bar.buttons, bar.x) end
    painter.bars = {}
    local rows = painter.canvas:rows()
    for index, row in ipairs(rows) do
        local gap = maximum(0, painter.width - tty.text.width(row))
        rows[index] = row .. appearance.style(painter.theme.text, painter.theme.surface) .. string.rep(" ", gap) .. RESET
    end
    return rows
end

-- Draws value at (x, y) within room cells and returns the drawn width.
function M.put(painter: Painter, x: integer, y: integer, value: string, room: integer, fg: string?, bg: string?): integer
    if y < 1 or y > painter.height or x < 1 or x > painter.width then return 0 end
    local size = minimum(room, painter.width - x + 1)
    if size <= 0 then return 0 end
    local fitted = M.fit(value, size)
    local drawn = tty.text.width(fitted)
    if drawn == 0 then return 0 end
    local theme = painter.theme
    painter.canvas:put(x, y, appearance.style(fg or theme.text, bg or theme.surface) .. fitted .. RESET, drawn)
    return drawn
end

-- Draws a decorative value (a pattern, a swatch or a border run) clipped to
-- room cells with no ellipsis; text a reader needs uses put.
function M.clip(painter: Painter, x: integer, y: integer, value: string, room: integer, fg: string?, bg: string?): integer
    if y < 1 or y > painter.height or x < 1 or x > painter.width then return 0 end
    local size = minimum(room, painter.width - x + 1)
    if size <= 0 then return 0 end
    local clipped = tty.text.truncate((value:gsub("[%z\1-\31\127]", " ")), size, "")
    local drawn = tty.text.width(clipped)
    if drawn == 0 then return 0 end
    local theme = painter.theme
    painter.canvas:put(x, y, appearance.style(fg or theme.text, bg or theme.surface) .. clipped .. RESET, drawn)
    return drawn
end

-- Clears row y to the surface, or to bg.
function M.fill(painter: Painter, y: integer, bg: string?)
    if y < 1 or y > painter.height or painter.width < 1 then return end
    local theme = painter.theme
    painter.canvas:put(1, y, appearance.style(theme.text, bg or theme.surface) .. string.rep(" ", painter.width) .. RESET, painter.width)
end

-- One content row: one blank cell at each edge, text from column 2.
function M.line(painter: Painter, y: integer, value: string, fg: string?, bg: string?)
    M.fill(painter, y, bg)
    M.put(painter, 2, y, value, painter.width - 2, fg, bg)
end

-- A full-width separator in the border role.
function M.rule(painter: Painter, y: integer)
    if y < 1 or y > painter.height then return end
    M.put(painter, 1, y, string.rep("─", painter.width), painter.width, painter.theme.border)
end

-- Records a target clipped to the canvas; targets outside it are dropped.
function M.add_hit(painter: Painter, kind: string, index: integer, key: string, x: integer, y: integer, width: integer, height: integer)
    if width <= 0 or height <= 0 or x < 1 or y < 1 or x > painter.width or y > painter.height then return end
    painter.hits[#painter.hits + 1] = {kind = kind, index = index, key = key, x = x, y = y,
        width = minimum(width, painter.width - x + 1), height = minimum(height, painter.height - y + 1)}
end

-- The first recorded target containing the cell (x, y), if any.
function M.hit(hits: {Hit}, x: integer, y: integer): Hit?
    for _, item in ipairs(hits) do
        if x >= item.x and x < item.x + item.width and y >= item.y and y < item.y + item.height then return item end
    end
    return nil
end

-- Row 1: the uppercase identity at the left and an optional muted live summary
-- aligned right. The summary never overlaps the title; it is truncated first
-- and omitted when fewer than four cells remain.
function M.header(painter: Painter, title: string, summary: string?)
    M.line(painter, 1, title, painter.theme.text)
    if not summary or summary == "" then return end
    local used = 1 + tty.text.width(M.fit(title, painter.width - 2))
    local room = painter.width - 1 - (used + 2)
    if room < 4 then return end
    local shown = M.fit(summary, room)
    local size = tty.text.width(shown)
    M.put(painter, painter.width - size, 1, shown, size, painter.theme.muted)
end

-- A tab row. Every label switches to its short form when the full set does not
-- fit. Returns the column after the last drawn tab.
function M.tabs(painter: Painter, y: integer, tabs: {Tab}, selected: string): integer
    for _, tab in ipairs(tabs) do
        painter.controls.buttons[#painter.controls.buttons + 1] = {kind = tab.kind, label = tab.label, enabled = true}
    end
    local full = 1
    for _, tab in ipairs(tabs) do full = full + tty.text.width(" " .. tab.label .. " ") + 1 end
    local compact = full > painter.width
    local theme = painter.theme
    local x = 2
    for index, tab in ipairs(tabs) do
        local label = " " .. ((compact and tab.short) or tab.label) .. " "
        local size = tty.text.width(label)
        if x + size - 1 > painter.width then break end
        local active = tab.kind == selected
        M.put(painter, x, y, label, size, active and appearance.selection_text(theme) or theme.muted,
            active and theme.accent or theme.surface)
        M.add_hit(painter, tab.kind, index, "", x, y, size, 1)
        x = x + size + 1
    end
    return x
end

local function draw_button(painter: Painter, x: integer, y: integer, button: Button): integer
    local label = " " .. (button.key and (button.key .. " ") or "") .. button.label .. " "
    local size = tty.text.width(label)
    if x < 1 or x + size - 1 > painter.width - 1 or y < 1 or y > painter.height then return x end
    local theme = painter.theme
    local fg, bg = theme.muted, theme.surface
    if button.enabled then
        if button.primary or button.active then fg, bg = appearance.selection_text(theme), theme.accent
        else fg = theme.accent end
    end
    M.put(painter, x, y, label, size, fg, bg)
    if button.enabled then M.add_hit(painter, button.kind, 0, "", x, y, size, 1) end
    return x + size + 1
end

-- Declares one button in a row; rows() paints the row with shared overflow.
function M.button(painter: Painter, x: integer, y: integer, button: Button): integer
    local bar = painter.bars[y]
    if not bar then bar = {x = x, buttons = {}}; painter.bars[y] = bar end
    bar.buttons[#bar.buttons + 1] = button
    return x + tty.text.width(" " .. (button.key and (button.key .. " ") or "") .. button.label .. " ") + 1
end

-- The screen's declared buttons, overflow and complete key hints.
function M.controls(painter: Painter): Controls
    return painter.controls
end

local function button_width(button: Button): integer
    return tty.text.width(" " .. (button.key and (button.key .. " ") or "") .. button.label .. " ") + 1
end

-- Primary actions keep their place in a crowded bar; the rest remain in More.
function M.actions(painter: Painter, y: integer, buttons: {Button}, x: integer?): integer
    local column = x or 2
    local total = 0
    for _, button in ipairs(buttons) do
        total = total + button_width(button)
        painter.controls.buttons[#painter.controls.buttons + 1] = button
    end
    local room = painter.width - column
    if total - 1 <= room then
        for _, button in ipairs(buttons) do column = draw_button(painter, column, y, button) end
        return column
    end
    local more: Button = {kind = "frame_more", key = "F10", label = "More", enabled = true}
    local available = room - button_width(more)
    local chosen: {[integer]: boolean} = {}
    for _, primary in ipairs({true, false}) do
        for index, button in ipairs(buttons) do
            if (button.primary == true) == primary and button_width(button) <= available then
                chosen[index] = true
                available = available - button_width(button)
            end
        end
    end
    for index, button in ipairs(buttons) do
        if chosen[index] then column = draw_button(painter, column, y, button)
        else painter.controls.overflow[#painter.controls.overflow + 1] = button end
    end
    return draw_button(painter, column, y, more)
end

-- Canonical key-hint text: "↑↓ select · Enter open · Esc close".
function M.hints(hints: {Hint}): string
    local parts: {string} = {}
    for _, hint in ipairs(hints) do parts[#parts + 1] = hint.key .. " " .. hint.verb end
    return table.concat(parts, " · ")
end

-- The footer reserves a bounded region for hints and an always visible Help.
function M.footer(painter: Painter, status: string, hints: string)
    local y = painter.height
    painter.controls.status = status
    if y < 1 then return end
    for part in hints:gmatch("[^·]+") do
        local key, verb = part:match("^%s*(%S+)%s+(.+)%s*$")
        if key and verb then painter.controls.hints[#painter.controls.hints + 1] = {key = key, verb = verb:gsub("%s+$", "")} end
    end
    local theme = painter.theme
    M.fill(painter, y)
    local room = maximum(0, painter.width - 2)
    local help = M.fit("? help", room)
    local help_size = tty.text.width(help)
    local hint_room = maximum(0, room - help_size - 3)
    if status ~= "" then hint_room = maximum(0, hint_room - minimum(tty.text.width(status), room // 3) - 3) end
    local shown = M.fit(hints, hint_room)
    local size = tty.text.width(shown)
    local hint_x = painter.width - help_size - 3 - size
    if status ~= "" then M.put(painter, 2, y, status, maximum(0, hint_x - 4), theme.text) end
    if size > 0 then M.put(painter, hint_x, y, shown, size, theme.muted) end
    local help_x = painter.width - help_size
    M.put(painter, help_x, y, help, help_size, theme.accent)
    M.add_hit(painter, "frame_help", 0, "", help_x, y, help_size, 1)
end

-- The visible window of a scrolling list of count rows in capacity slots,
-- keeping the selected index (0 for none) visible.
function M.window(count: integer, capacity: integer, selected: integer, offset: integer): Window
    local slots = maximum(0, capacity)
    local last = maximum(0, count - slots)
    local value = maximum(0, minimum(last, offset))
    if selected > 0 and slots > 0 then
        if selected <= value then value = selected - 1 end
        if selected > value + slots then value = selected - slots end
    end
    return {offset = maximum(0, minimum(last, value)), capacity = slots}
end

-- A whole-row target. Selection keeps its text, uses the accent pair and marks
-- column 1 with "›" so focus is visible without color. Unfocused selection
-- (another pane owns focus) keeps the marker in accent on the surface. span
-- extends the target over the item's following rows.
-- One row confined to area's columns, with the marker column before it.
local function band(painter: Painter, area: Rect, y: integer, value: string, fg: string?, bg: string?)
    if y < 1 or y > painter.height or area.width <= 0 then return end
    local theme = painter.theme
    local x = maximum(1, area.x - 1)
    local room = minimum(area.x + area.width - x, painter.width - x + 1)
    if room > 0 then painter.canvas:put(x, y, appearance.style(theme.text, bg or theme.surface) .. string.rep(" ", room) .. RESET, room) end
    M.put(painter, area.x, y, value, area.width, fg, bg)
end

local function empty_area(area: Rect?): boolean
    return area ~= nil and (area.width <= 0 or area.height <= 0)
end

local function draw_row(painter: Painter, area: Rect?, y: integer, value: string, selected: boolean, kind: string, index: integer, key: string,
    fg: string?, focused: boolean?, span: integer?)
    if empty_area(area) then return end
    local theme = painter.theme
    local has_focus = focused == nil or focused
    local text_fg = fg or theme.text
    local bg = theme.surface
    if selected and has_focus then text_fg, bg = appearance.selection_text(theme), theme.accent
    elseif selected then text_fg = theme.accent end
    if area then
        local x = maximum(1, area.x - 1)
        band(painter, area, y, value, text_fg, bg)
        if selected and x < area.x then M.put(painter, x, y, MARKER, 1, text_fg, bg) end
        M.add_hit(painter, kind, index, key, x, y, area.x + area.width - x, span or 1)
        return
    end
    M.line(painter, y, value, text_fg, bg)
    if selected then M.put(painter, 1, y, MARKER, 1, text_fg, bg) end
    M.add_hit(painter, kind, index, key, 1, y, painter.width, span or 1)
end

function M.row(painter: Painter, y: integer, value: string, selected: boolean, kind: string, index: integer, key: string, fg: string?, focused: boolean?, span: integer?)
    draw_row(painter, nil, y, value, selected, kind, index, key, fg, focused, span)
end

-- Column geometry for a table at the canvas width, or nil when the flexible
-- column cannot keep at least its title width (the compact form applies).
local function layout(width: integer, columns: {Column}): {integer}?
    local room = width - 2
    local fixed, flexible = 0, 0
    for _, column in ipairs(columns) do
        if column.width > 0 then fixed = fixed + column.width else flexible = flexible + 1 end
    end
    local gaps = 2 * (#columns - 1)
    local rest = room - fixed - gaps
    local widths: {integer} = {}
    for index, column in ipairs(columns) do
        if column.width > 0 then widths[index] = column.width
        else
            local minimum_width = maximum(8, tty.text.width(column.title))
            if flexible ~= 1 or rest < minimum_width then return nil end
            widths[index] = rest
        end
    end
    if flexible == 0 and rest < 0 then return nil end
    return widths
end

local function joined(values: {string}, widths: {integer}, columns: {Column}): string
    local parts: {string} = {}
    for index, value in ipairs(values) do
        parts[#parts + 1] = M.pad(value, widths[index], columns[index].align)
    end
    return table.concat(parts, "  ")
end

-- A table between rows first and last: a muted column caption on row first and
-- rows below it. On a narrow canvas each row becomes its first cell followed
-- by the other nonempty cells joined with " · ". Returns the visible window.
function M.table(painter: Painter, first: integer, last: integer, value: Table): Window
    local count = #value.cells
    if last < first then return {offset = 0, capacity = 0} end
    local area = value.area
    local span = painter.width
    if area then span = area.width + 2 end
    local widths = layout(span, value.columns)
    local captions: {string} = {}
    for index, column in ipairs(value.columns) do captions[index] = string.upper(column.title) end
    local caption = ""
    if widths then caption = joined(captions, widths, value.columns)
    else
        caption = captions[1]
        for index = 2, #captions do if captions[index] ~= "" then caption = caption .. " · " .. captions[index] end end
    end
    if area then band(painter, area, first, caption, painter.theme.muted)
    else M.line(painter, first, caption, painter.theme.muted) end
    local window = M.window(count, last - first, value.selected, value.offset)
    for slot = 1, window.capacity do
        local index = window.offset + slot
        local cells = value.cells[index]
        if not cells then break end
        local text = ""
        if widths then text = joined(cells, widths, value.columns)
        else
            text = cells[1] or ""
            for column = 2, #cells do if cells[column] ~= "" then text = text .. " · " .. cells[column] end end
        end
        draw_row(painter, area, first + slot, text, index == value.selected, value.kind, index,
            value.keys and value.keys[index] or "", nil, value.focused)
    end
    return window
end

-- The size class of a canvas: "narrow" below 80x24, "compact" from 80x24,
-- "standard" from 120x36 and "wide" from 160x48. Both dimensions must reach a
-- class; layouts change only at these breakpoints.
function M.size(width: integer, height: integer): string
    if width >= 160 and height >= 48 then return "wide" end
    if width >= 120 and height >= 36 then return "standard" end
    if width >= 80 and height >= 24 then return "compact" end
    return "narrow"
end

-- The canonical anatomy for this canvas: header on row 1, tabs on row 2 when
-- requested and the canvas has at least 6 rows, one blank row, the work area
-- from column 2 to the column before the last, the action bar on the
-- penultimate row when requested and the canvas has at least 6 rows, and the
-- footer on the final row when the canvas has at least 2 rows.
function M.layout(painter: Painter, tabs: boolean, actions: boolean): Layout
    local height = painter.height
    local roomy = height >= 6
    local tab_row = (tabs and roomy) and 2 or 0
    local action_row = (actions and roomy) and height - 1 or 0
    local footer_row = height >= 2 and height or 0
    local first = roomy and (tab_row > 0 and 4 or 3) or 2
    local last = action_row > 0 and action_row - 1 or (footer_row > 0 and footer_row - 1 or height)
    return {size = M.size(painter.width, height), tabs = tab_row, actions = action_row, footer = footer_row,
        work = {x = 2, y = first, width = maximum(0, painter.width - 2), height = maximum(0, last - first + 1)}}
end

local function spans(total: integer, sizes: {integer}, gap: integer): {integer}
    local fixed, flexible = 0, 0
    for _, size in ipairs(sizes) do
        if size > 0 then fixed = fixed + size else flexible = flexible + 1 end
    end
    local rest = maximum(0, total - fixed - gap * maximum(0, #sizes - 1))
    local result: {integer} = {}
    local given = 0
    for index, size in ipairs(sizes) do
        if size > 0 then result[index] = size
        else
            local share = rest // maximum(1, flexible)
            if given < rest % maximum(1, flexible) then share = share + 1 end
            given = given + 1
            result[index] = share
        end
    end
    return result
end

-- Splits a rectangle into columns left to right. A size of 0 is flexible and
-- shares the remaining width; gap (default 2) separates the columns. Columns
-- that do not fit keep their position with a clipped width.
function M.split(rect: Rect, sizes: {integer}, gap: integer?): {Rect}
    local space = gap or 2
    local result: {Rect} = {}
    local x = rect.x
    for index, size in ipairs(spans(rect.width, sizes, space)) do
        local width = maximum(0, minimum(size, rect.x + rect.width - x))
        result[index] = {x = x, y = rect.y, width = width, height = rect.height}
        x = x + size + space
    end
    return result
end

-- Splits a rectangle into rows top to bottom, like split; gap defaults to 1.
function M.stack(rect: Rect, sizes: {integer}, gap: integer?): {Rect}
    local space = gap or 1
    local result: {Rect} = {}
    local y = rect.y
    for index, size in ipairs(spans(rect.height, sizes, space)) do
        local height = maximum(0, minimum(size, rect.y + rect.height - y))
        result[index] = {x = rect.x, y = y, width = rect.width, height = height}
        y = y + size + space
    end
    return result
end

-- A dashboard grid of columns by rows equal cells in reading order, two cells
-- between columns and one row between rows. Leftover cells go to the first
-- columns and rows.
function M.grid(rect: Rect, columns: integer, rows: integer): {Rect}
    local widths: {integer} = {}
    for index = 1, maximum(1, columns) do widths[index] = 0 end
    local heights: {integer} = {}
    for index = 1, maximum(1, rows) do heights[index] = 0 end
    local result: {Rect} = {}
    for _, line in ipairs(M.stack(rect, heights, 1)) do
        for _, cell in ipairs(M.split(line, widths, 2)) do result[#result + 1] = cell end
    end
    return result
end

-- A titled panel without a border: the uppercase title in muted at the top of
-- rect, an optional summary aligned right in text, and the returned rectangle
-- below the title for the panel's content.
function M.panel(painter: Painter, rect: Rect, title: string, summary: string?): Rect
    if rect.width <= 0 or rect.height <= 0 then return {x = rect.x, y = rect.y, width = 0, height = 0} end
    local drawn = M.put(painter, rect.x, rect.y, string.upper(title), rect.width, painter.theme.muted)
    if summary and summary ~= "" then
        local room = rect.width - drawn - 2
        if room >= 4 then
            local shown = M.fit(summary, room)
            local size = tty.text.width(shown)
            M.put(painter, rect.x + rect.width - size, rect.y, shown, size, painter.theme.text)
        end
    end
    return {x = rect.x, y = rect.y + 1, width = rect.width, height = rect.height - 1}
end

-- A selectable dashboard card: a panel titled title whose whole rectangle is a
-- hit of kind at index, with the selection marker in column rect.x - 1 when
-- selected. Returns the panel's content rectangle.
function M.card(painter: Painter, rect: Rect, kind: string, index: integer, title: string, selected: boolean): Rect
    if rect.width <= 0 or rect.height <= 0 then return {x = rect.x, y = rect.y, width = 0, height = 0} end
    local inner = M.panel(painter, rect, title, selected and "selected" or nil)
    M.add_hit(painter, kind, index, title, rect.x, rect.y, rect.width, rect.height)
    if selected then M.put(painter, rect.x - 1, rect.y, "›", 1, painter.theme.accent) end
    return inner
end

-- Lays count cards in rect and calls draw(cell, index) for each: a grid of two
-- columns on compact canvases, of two (four or more cards) or count columns on
-- larger ones, and only the selected card, filling rect, on narrow canvases.
function M.cards(painter: Painter, rect: Rect, count: integer, selected: integer, draw: (Rect, integer) -> ())
    if rect.width <= 0 or rect.height <= 0 or count < 1 then return end
    local size = M.size(painter.width, painter.height)
    if size == "narrow" then
        draw(rect, maximum(1, minimum(count, selected)))
        return
    end
    local columns = size == "compact" and 2 or (count >= 4 and 2 or count)
    local cells = M.grid(rect, columns, (count + columns - 1) // columns)
    for index = 1, minimum(count, #cells) do draw(cells[index], index) end
end

-- Splits rect into a list pane and a detail pane on canvases of at least 100
-- columns by 24 rows (list 60 columns, detail the rest); otherwise the list
-- fills rect and the detail is nil.
function M.master_detail(painter: Painter, rect: Rect): (Rect, Rect?)
    if painter.width >= 100 and painter.height >= 24 then
        local panes = M.split(rect, {60, 0}, 2)
        return panes[1], panes[2]
    end
    return rect, nil
end

-- One form field on row y: the muted label padded to label_width, then the
-- value. The selected field takes the row selection and its target; an error
-- replaces the value's trailing room in the error role after " · ".
function M.field(painter: Painter, y: integer, label: string, value: string, label_width: integer, selected: boolean, index: integer, error_text: string?)
    local text = M.pad(label, label_width) .. "  " .. value
    M.row(painter, y, text, selected, "field", index, "")
    if not selected then M.put(painter, 2, y, M.pad(label, label_width), label_width, painter.theme.muted) end
    if error_text and error_text ~= "" then
        local x = 2 + tty.text.width(M.fit(text, painter.width - 2)) + 1
        M.put(painter, x, y, "· " .. error_text, painter.width - x, painter.theme.error,
            selected and painter.theme.accent or painter.theme.surface)
    end
end

-- A wizard step strip on row y: "1 Source › 2 Review › 3 Deliver". The current
-- step uses the accent pair, finished steps carry "✓" and later steps are muted.
-- On a narrow row only the current step shows, as "Step 2/3 Review".
function M.steps(painter: Painter, y: integer, labels: {string}, current: integer)
    M.fill(painter, y)
    local parts: {string} = {}
    for index, label in ipairs(labels) do
        parts[index] = (index < current and "✓ " or (tostring(index) .. " ")) .. label
    end
    local full = 0
    for index, part in ipairs(parts) do full = full + tty.text.width(part) + (index > 1 and 3 or 0) + 2 end
    local theme = painter.theme
    if full > painter.width - 2 then
        local label = labels[current] or ""
        M.put(painter, 2, y, " Step " .. tostring(current) .. "/" .. tostring(#labels) .. " " .. label .. " ",
            painter.width - 2, appearance.selection_text(theme), theme.accent)
        return
    end
    local x = 2
    for index, part in ipairs(parts) do
        if index > 1 then x = x + M.put(painter, x, y, " › ", 3, theme.muted) end
        local label = " " .. part .. " "
        if index == current then x = x + M.put(painter, x, y, label, painter.width - x, appearance.selection_text(theme), theme.accent)
        else x = x + M.put(painter, x, y, label, painter.width - x, index < current and theme.text or theme.muted) end
    end
end

-- An empty, loading or failure state: what is absent or wrong on row y and the
-- next useful action on the row below it. Inside a panel, area bounds both
-- rows to the panel's columns and leaves the rest of the rows untouched.
function M.empty(painter: Painter, y: integer, title: string, action: string?, area: Rect?)
    local has_action = action ~= nil and action ~= ""
    if area then
        if area.width <= 0 or area.height <= 0 then return end
        M.put(painter, area.x, y, title, area.width, painter.theme.text)
        if has_action and y + 1 < area.y + area.height then
            M.put(painter, area.x, y + 1, action or "", area.width, painter.theme.muted)
        end
        return
    end
    M.line(painter, y, title, painter.theme.text)
    if has_action then M.line(painter, y + 1, action or "", painter.theme.muted) end
end

-- A tree view between rows first and last: only the visible window is ever
-- drawn. Each row is indented two cells per depth, then "▾" expanded, "▸"
-- collapsed, or two blank cells for a leaf, then its label; role colors the
-- label (default text). The selected row takes the row selection; every
-- drawn row carries hit kind "tree" and its key. Returns the visible window.
function M.tree(painter: Painter, first: integer, last: integer, value: TreeView): Window
    local count = #value.rows
    if last < first then return {offset = 0, capacity = 0} end
    local window = M.window(count, last - first + 1, value.selected, value.offset)
    for slot = 1, window.capacity do
        local index = window.offset + slot
        local row = value.rows[index]
        if not row then break end
        local marker = row.expandable and (row.expanded and "▾ " or "▸ ") or "  "
        local text = string.rep("  ", maximum(0, row.depth)) .. marker .. row.label
        draw_row(painter, value.area, first + slot - 1, text, index == value.selected, "tree", index, row.key or "",
            row.role and appearance.role(painter.theme, row.role) or nil, value.focused)
    end
    return window
end

-- A key-value inspector between rows first and last: the muted label padded
-- to label_width (default the widest label, capped to a third of the
-- canvas) then the value in role (default text). The selected row takes the
-- row selection and carries hit kind "kv"; every row keeps its label as the
-- key. Returns the visible window.
function M.kv(painter: Painter, first: integer, last: integer, value: Inspector): Window
    local count = #value.entries
    if last < first then return {offset = 0, capacity = 0} end
    local label_width = value.label_width or 0
    if label_width <= 0 then
        for _, entry in ipairs(value.entries) do label_width = maximum(label_width, tty.text.width(entry.label)) end
    end
    local span = value.area and value.area.width or painter.width
    label_width = minimum(label_width, span // 3)
    local window = M.window(count, last - first + 1, value.selected, value.offset)
    for slot = 1, window.capacity do
        local index = window.offset + slot
        local entry = value.entries[index]
        if not entry then break end
        local y = first + slot - 1
        local text = M.pad(entry.label, label_width) .. "  " .. entry.value
        draw_row(painter, value.area, y, text, index == value.selected, "kv", index, entry.label,
            entry.role and appearance.role(painter.theme, entry.role) or nil, value.focused)
        if index ~= value.selected then M.put(painter, value.area and value.area.x or 2, y, M.pad(entry.label, label_width), label_width, painter.theme.muted) end
    end
    return window
end

-- text painted at (x, y) in fg over bg, with every case-insensitive
-- occurrence of query picked out in the accent pair. A valid UTF-8 query
-- only ever matches on a UTF-8 character boundary of a valid UTF-8 text, so
-- the split never lands inside a multi-byte glyph.
local function highlighted(painter: Painter, x: integer, y: integer, text: string, room: integer, query: string?, fg: string?, bg: string?)
    if not query or query == "" or room <= 0 then M.put(painter, x, y, text, room, fg, bg); return end
    local fitted = M.fit(text, room)
    local haystack = fitted:lower()
    local needle = query:lower()
    local theme = painter.theme
    local column = x
    local budget = room
    local at = 1
    while budget > 0 do
        local found = haystack:find(needle, at, true)
        if not found then
            column = column + M.put(painter, column, y, fitted:sub(at), budget, fg, bg)
            break
        end
        if found > at then
            local used = M.put(painter, column, y, fitted:sub(at, found - 1), budget, fg, bg)
            column = column + used
            budget = budget - used
        end
        if budget <= 0 then break end
        local used = M.put(painter, column, y, fitted:sub(found, found + #query - 1), budget, appearance.selection_text(theme), theme.accent)
        column = column + used
        budget = budget - used
        at = found + maximum(1, #query)
    end
end

-- A virtualized log viewer between rows first and last: only the visible
-- window of lines is ever drawn. Each line is colored by its role (default
-- text), and every occurrence of query (case-insensitive) is picked out in
-- the accent pair. The selected line takes the row selection; every drawn
-- line carries hit kind "log" and its index. Returns the visible window.
function M.log(painter: Painter, first: integer, last: integer, value: LogView): Window
    local count = #value.lines
    if last < first then return {offset = 0, capacity = 0} end
    local window = M.window(count, last - first + 1, value.selected, value.offset)
    if empty_area(value.area) then return window end
    local theme = painter.theme
    for slot = 1, window.capacity do
        local index = window.offset + slot
        local line = value.lines[index]
        if not line then break end
        local y = first + slot - 1
        local selected = index == value.selected
        local has_focus = value.focused == nil or value.focused
        local fg = line.role and appearance.role(theme, line.role) or theme.text
        local bg = theme.surface
        if selected and has_focus then fg, bg = appearance.selection_text(theme), theme.accent
        elseif selected then fg = theme.accent end
        local area = value.area
        if area then
            local marker_x = maximum(1, area.x - 1)
            band(painter, area, y, "", fg, bg)
            if selected and marker_x < area.x then M.put(painter, marker_x, y, MARKER, 1, fg, bg) end
            highlighted(painter, area.x, y, line.text, area.width, value.query, fg, bg)
            M.add_hit(painter, "log", index, "", marker_x, y, area.x + area.width - marker_x, 1)
        else
            M.fill(painter, y, bg)
            if selected then M.put(painter, 1, y, MARKER, 1, fg, bg) end
            highlighted(painter, 2, y, line.text, painter.width - 2, value.query, fg, bg)
            M.add_hit(painter, "log", index, "", 1, y, painter.width, 1)
        end
    end
    return window
end

-- A status badge at (x, y): text padded with one cell on each side, filled
-- in role's color (default accent) with a contrasting foreground. Returns
-- the drawn width.
function M.badge(painter: Painter, x: integer, y: integer, text: string, role: string?): integer
    local label = " " .. text .. " "
    local size = tty.text.width(label)
    local bg = appearance.role(painter.theme, role or "accent")
    return M.put(painter, x, y, label, size, appearance.selection_text(painter.theme), bg)
end

-- A one-row toast notification: the message centered on row y, filled in
-- role's color (default accent) with a contrasting foreground, overwriting
-- whatever was on that row. The caller owns when a toast is shown and for
-- how long; this only draws the row.
function M.toast(painter: Painter, y: integer, toast: Toast)
    if y < 1 or y > painter.height then return end
    local bg = appearance.role(painter.theme, toast.role or "accent")
    M.fill(painter, y, bg)
    local text = M.fit(toast.text, maximum(0, painter.width - 4))
    local size = tty.text.width(text)
    M.put(painter, maximum(1, (painter.width - size) // 2 + 1), y, text, size, appearance.selection_text(painter.theme), bg)
end

-- A centered modal panel: a box-drawing border in the border role clipped to
-- width by height (each capped to the painter's size), the title on its top
-- edge and the surface cleared underneath. Returns the inner rectangle for
-- the caller's own content; too little room returns a zero rectangle and
-- paints nothing.
function M.modal(painter: Painter, width: integer, height: integer, title: string): Rect
    local w = maximum(0, minimum(width, painter.width))
    local h = maximum(0, minimum(height, painter.height))
    if w < 4 or h < 3 then return {x = 0, y = 0, width = 0, height = 0} end
    local x = maximum(1, (painter.width - w) // 2 + 1)
    local y = maximum(1, (painter.height - h) // 2 + 1)
    local theme = painter.theme
    for row = 0, h - 1 do
        painter.canvas:put(x, y + row, appearance.style(theme.text, theme.surface) .. string.rep(" ", w) .. RESET, w)
    end
    M.put(painter, x, y, "┌" .. string.rep("─", w - 2) .. "┐", w, theme.border)
    for row = 1, h - 2 do
        M.put(painter, x, y + row, "│", 1, theme.border)
        M.put(painter, x + w - 1, y + row, "│", 1, theme.border)
    end
    M.put(painter, x, y + h - 1, "└" .. string.rep("─", w - 2) .. "┘", w, theme.border)
    if title ~= "" then M.put(painter, x + 2, y, " " .. title .. " ", maximum(0, w - 4), theme.text) end
    return {x = x + 2, y = y + 1, width = maximum(0, w - 4), height = maximum(0, h - 2)}
end

-- A subsequence match score for a command palette: nil when query's
-- characters (case-folded) do not all appear in order within text, else a
-- score where a lower number ranks a tighter, earlier match higher.
function M.fuzzy(query: string, text: string): integer?
    if query == "" then return 0 end
    local needle = query:lower()
    local haystack = text:lower()
    local at = 1
    local first: integer? = nil
    local last = 0
    for position = 1, #needle do
        local found = haystack:find(needle:sub(position, position), at, true)
        if not found then return nil end
        first = first or found
        last = found
        at = found + 1
    end
    return (last - (first or 1)) + (first or 1)
end

-- The palette choices for query over labels: every label that fuzzy matches,
-- best match first and in list order among equal scores, each keyed by its label.
function M.ranked(query: string, labels: {string}): {Choice}
    local scored: {{score: integer, order: integer, label: string}} = {}
    for order, label in ipairs(labels) do
        local score = M.fuzzy(query, label)
        if score then scored[#scored + 1] = {score = score, order = order, label = label} end
    end
    table.sort(scored, function(a, b)
        if a.score ~= b.score then return a.score < b.score end
        return a.order < b.order
    end)
    local choices: {Choice} = {}
    for _, item in ipairs(scored) do choices[#choices + 1] = {label = item.label, key = item.label} end
    return choices
end

-- A command palette overlay: a modal titled "Command Palette" sized to
-- width by height, the query on its first content row with a block caret,
-- and the choices below as selectable rows carrying hit kind "choice" and
-- each choice's key. An empty choices list draws the empty state instead of
-- a list. Returns the visible window of choices.
function M.palette(painter: Painter, width: integer, height: integer, value: Palette): Window
    local content = M.modal(painter, width, height, "Command Palette")
    if content.width <= 0 or content.height <= 0 then return {offset = 0, capacity = 0} end
    M.put(painter, content.x, content.y, "› " .. value.query .. "█", content.width, painter.theme.text)
    if content.height < 3 then return {offset = 0, capacity = 0} end
    if #value.choices == 0 then
        M.empty(painter, content.y + 2, "No matches", nil, {x = content.x, y = content.y, width = content.width, height = content.height})
        return {offset = 0, capacity = 0}
    end
    local first = content.y + 2
    local last = content.y + content.height - 1
    local window = M.window(#value.choices, last - first + 1, value.selected, value.offset)
    for slot = 1, window.capacity do
        local index = window.offset + slot
        local choice = value.choices[index]
        if not choice then break end
        local text = choice.label .. ((choice.note and choice.note ~= "") and ("  " .. choice.note) or "")
        draw_row(painter, content, first + slot - 1, text, index == value.selected, "choice", index, choice.key or "", nil, true)
    end
    return window
end

-- An app-owned More and Help state; the app retains it between redraws.
function M.menu(): Menu
    local controls: Controls = {buttons = {}, overflow = {}, hints = {}, status = ""}
    return {mode = "", selected = 1, offset = 0, controls = controls, hits = {}, signature = "", count = 0}
end

local function choices(menu: Menu): {Button}
    if menu.mode == "more" then return menu.controls.overflow end
    return menu.controls.buttons
end

-- Paints a shared overlay from this screen's declared buttons and hints.
function M.render(view: View, menu: Menu, preferences: appearance.Preferences)
    local controls: Controls
    if view.controls then controls = view.controls
    else controls = {buttons = {}, overflow = {}, hints = {}, status = ""} end
    local parts: {string} = {}
    for _, button in ipairs(controls.buttons) do parts[#parts + 1] = button.kind end
    for _, hint in ipairs(controls.hints) do parts[#parts + 1] = hint.key .. hint.verb end
    local signature = table.concat(parts, "\n")
    if signature ~= menu.signature then menu.mode, menu.selected, menu.offset = "", 1, 0 end
    menu.signature, menu.controls = signature, controls
    if menu.mode == "more" and #controls.overflow == 0 then menu.mode = "" end
    if menu.mode == "" then menu.hits = view.hits; return end
    local painter = M.new(tty.text.width(view.rows[1] or ""), #view.rows, preferences)
    M.header(painter, menu.mode == "more" and "MORE ACTIONS" or "HELP", "Esc back")
    M.add_hit(painter, "frame_back", 0, "", maximum(1, painter.width - 8), 1, 8, 1)
    local items = choices(menu)
    local lines: {string} = {}
    for _, button in ipairs(items) do
        lines[#lines + 1] = (button.key and (button.key .. "  ") or "") .. button.label .. (button.enabled and "" or " · unavailable")
    end
    if menu.mode == "help" then
        for _, hint in ipairs(controls.hints) do lines[#lines + 1] = hint.key .. "  " .. hint.verb end
        lines[#lines + 1] = "F10  More actions"
        lines[#lines + 1] = "?  Help"
        local status = controls.status or ""
        if status ~= "" then
            local remaining = "Status: " .. status
            while remaining ~= "" and painter.width > 2 do
                local shown = tty.text.truncate(remaining, painter.width - 2, "")
                if shown == "" then break end
                lines[#lines + 1] = shown
                remaining = remaining:sub(#shown + 1)
            end
        end
    end
    menu.count = #lines
    menu.selected = minimum(maximum(1, menu.selected), maximum(1, #lines))
    local window = M.window(#lines, painter.height - 4, menu.selected, menu.offset)
    menu.offset = window.offset
    for slot = 1, window.capacity do
        local index = window.offset + slot
        if not lines[index] then break end
        local button = items[index]
        M.row(painter, slot + 2, lines[index], index == menu.selected, "frame_choice", index, "",
            button and not button.enabled and painter.theme.muted or nil)
    end
    M.footer(painter, "", menu.mode == "more" and "↑↓ select · Enter choose · Esc back" or "↑↓ scroll · Esc back")
    view.rows, view.hits = M.rows(painter), painter.hits
    menu.hits = view.hits
end

local function choose(menu: Menu, index: integer): tty.TTYEvent?
    local button = choices(menu)[index]
    if menu.mode ~= "more" or not button or not button.enabled then return nil end
    for _, hit in ipairs(menu.hits) do
        if hit.kind == "frame_choice" and hit.index == index then
            hit.kind, hit.index = button.kind, 0
            menu.mode = ""
            return {type = "mouse", action = "press", button = "left", x = hit.x, y = hit.y, ctrl = false, alt = false, shift = false}
        end
    end
    return nil
end

local function coordinate(value: unknown): integer?
    if type(value) ~= "number" or value ~= value or value < 1 or value > 2147483647 or value ~= math.floor(value) then return nil end
    return math.floor(value)
end
local function input_event(value: unknown): tty.TTYEvent?
    if type(value) ~= "table" then return nil end
    if value.ctrl ~= nil and type(value.ctrl) ~= "boolean" then return nil end
    if value.alt ~= nil and type(value.alt) ~= "boolean" then return nil end
    if value.shift ~= nil and type(value.shift) ~= "boolean" then return nil end
    if value.type == "key" then
        if (value.key ~= nil and type(value.key) ~= "string") or type(value.key_type) ~= "string" or (value.action ~= "press" and value.action ~= "release") then return nil end
        return {type = "key", key = type(value.key) == "string" and value.key or "", key_type = value.key_type, action = value.action == "release" and "release" or "press", ctrl = value.ctrl == true, alt = value.alt == true, shift = value.shift == true}
    elseif value.type == "mouse" then
        local x, y = coordinate(value.x), coordinate(value.y)
        if not x or not y or type(value.button) ~= "string" or (value.action ~= "press" and value.action ~= "release" and value.action ~= "motion" and value.action ~= "wheel") then return nil end
        return {type = "mouse", x = x, y = y, button = value.button, action = value.action == "release" and "release" or (value.action == "motion" and "motion" or (value.action == "wheel" and "wheel" or "press")), ctrl = value.ctrl == true, alt = value.alt == true, shift = value.shift == true}
    elseif value.type == "start" or value.type == "resize" then
        local width, height = coordinate(value.width), coordinate(value.height)
        if not width or not height then return nil end
        if value.type == "start" then return {type = "start", width = width, height = height} end
        return {type = "resize", width = width, height = height}
    elseif value.type == "paste" and type(value.text) == "string" then return {type = "paste", text = value.text}
    elseif value.type == "focus" and type(value.focused) == "boolean" then return {type = "focus", focused = value.focused}
    elseif value.type == "visibility" and type(value.visible) == "boolean" then return {type = "visibility", visible = value.visible}
    elseif value.type == "close" then return {type = "close"} end
    return nil
end

-- Returns nil for consumed input. Selected actions reuse the app's mouse path.
-- text_entry preserves letters and '?' while a form or editor owns input.
function M.route(menu: Menu, value: unknown, text_entry: boolean?): (tty.TTYEvent?, boolean)
    local event = input_event(value)
    if not event then return nil, false end
    if event.type == "start" or event.type == "resize" or event.type == "close" then return event, false end
    if event.type == "key" and event.action ~= "release" then
        local key, letter = event.key_type or "", event.key or ""
        local plain = not event.ctrl and not event.alt
        if plain and (key == "f10" or (letter == "?" and not text_entry)) then
            local mode = key == "f10" and "more" or "help"
            if mode ~= "more" or #menu.controls.overflow > 0 then
                menu.mode = menu.mode == mode and "" or mode
                menu.selected, menu.offset = 1, 0
                return nil, true
            end
        end
        if menu.mode ~= "" then
            if key == "esc" or key == "escape" then menu.mode = ""
            elseif key == "up" then menu.selected = maximum(1, menu.selected - 1)
            elseif key == "down" then menu.selected = menu.selected + 1
            elseif key == "tab" then menu.selected = menu.selected + (event.shift and -1 or 1)
            elseif key == "pgup" then menu.selected = maximum(1, menu.selected - 8)
            elseif key == "pgdown" then menu.selected = menu.selected + 8
            elseif key == "home" then menu.selected = 1
            elseif key == "end" then menu.selected = menu.count
            elseif key == "enter" then return choose(menu, menu.selected), true
            elseif plain and menu.mode == "more" then
                for index, button in ipairs(choices(menu)) do
                    if button.key and button.key:lower() == letter:lower() then return choose(menu, index), true end
                end
            end
            return nil, true
        end
    elseif event.type == "mouse" then
        local hit = M.hit(menu.hits, event.x or 0, event.y or 0)
        if event.action == "press" and event.button == "left" and hit then
            if hit.kind == "frame_back" then
                menu.mode = ""
                return nil, true
            elseif hit.kind == "frame_more" or hit.kind == "frame_help" then
                menu.mode = hit.kind == "frame_more" and "more" or "help"
                menu.selected, menu.offset = 1, 0
                return nil, true
            elseif hit.kind == "frame_choice" and menu.mode == "more" then return choose(menu, hit.index), true end
        end
        if menu.mode ~= "" then
            if event.action == "wheel" then menu.selected = maximum(1, menu.selected + ((event.button == "wheel_up" or event.button == "up") and -1 or 1)) end
            return nil, true
        end
    end
    if menu.mode ~= "" then return nil, false end
    if event.type == "key" and event.key and event.action ~= "release" and (not text_entry or event.ctrl) and not event.alt then
        return {type = "key", action = event.action, key = event.key:lower(), key_type = event.key_type,
            ctrl = event.ctrl, alt = event.alt, shift = event.shift}, false
    end
    return event, false
end

return M
