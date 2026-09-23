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
type Painter = {width: integer, height: integer, theme: appearance.Theme, canvas: tty.Canvas, hits: {Hit}}
-- A button with a key is drawn as "Key Label"; primary marks the one filled
-- action, active a selected toggle. Disabled buttons stay visible and have no hit.
type Button = {kind: string, label: string, enabled: boolean, primary: boolean?, active: boolean?, key: string?}
type Tab = {kind: string, label: string, short: string?}
type Hint = {key: string, verb: string}
type Window = {offset: integer, capacity: integer}
-- A table column: width 0 is the single flexible column; align "right" for numbers.
type Column = {title: string, width: integer, align: string?}
type Table = {columns: {Column}, cells: {{string}}, keys: {string}?, kind: string, selected: integer, offset: integer, focused: boolean?}

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
    return {width = width, height = height, theme = theme, canvas = canvas, hits = {}}
end

-- The painted rows, ready for output:present.
function M.rows(painter: Painter): {string}
    return painter.canvas:rows()
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

-- One button at (x, y); returns the next column, unchanged when it does not fit.
function M.button(painter: Painter, x: integer, y: integer, button: Button): integer
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

-- The action bar: buttons in order from column x (default 2) on row y.
function M.actions(painter: Painter, y: integer, buttons: {Button}, x: integer?): integer
    local column = x or 2
    for _, button in ipairs(buttons) do column = M.button(painter, column, y, button) end
    return column
end

-- Canonical key-hint text: "↑↓ select · Enter open · Esc close".
function M.hints(hints: {Hint}): string
    local parts: {string} = {}
    for _, hint in ipairs(hints) do parts[#parts + 1] = hint.key .. " " .. hint.verb end
    return table.concat(parts, " · ")
end

-- The final row: the changing status at the left and the stable key hints at
-- the right. A status wins the row when both do not fit; with no status the
-- hints stand alone.
function M.footer(painter: Painter, status: string, hints: string)
    local y = painter.height
    if y < 1 then return end
    local theme = painter.theme
    M.fill(painter, y)
    local room = painter.width - 2
    if status == "" then
        M.put(painter, 2, y, hints, room, theme.muted)
        return
    end
    local drawn = M.put(painter, 2, y, status, room, theme.text)
    local size = tty.text.width(hints)
    if hints ~= "" and drawn + 4 + size <= room then
        M.put(painter, painter.width - size, y, hints, size, theme.muted)
    end
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
function M.row(painter: Painter, y: integer, value: string, selected: boolean, kind: string, index: integer, key: string, fg: string?, focused: boolean?, span: integer?)
    local theme = painter.theme
    local has_focus = focused == nil or focused
    local text_fg = fg or theme.text
    local bg = theme.surface
    if selected and has_focus then text_fg, bg = appearance.selection_text(theme), theme.accent
    elseif selected then text_fg = theme.accent end
    M.line(painter, y, value, text_fg, bg)
    if selected then M.put(painter, 1, y, MARKER, 1, text_fg, bg) end
    M.add_hit(painter, kind, index, key, 1, y, painter.width, span or 1)
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
    local widths = layout(painter.width, value.columns)
    local captions: {string} = {}
    for index, column in ipairs(value.columns) do captions[index] = string.upper(column.title) end
    if widths then M.line(painter, first, joined(captions, widths, value.columns), painter.theme.muted)
    else
        local compact = captions[1]
        for index = 2, #captions do if captions[index] ~= "" then compact = compact .. " · " .. captions[index] end end
        M.line(painter, first, compact, painter.theme.muted)
    end
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
        M.row(painter, first + slot, text, index == value.selected, value.kind, index,
            value.keys and value.keys[index] or "", nil, value.focused)
    end
    return window
end

-- An empty, loading or failure state: what is absent or wrong on row y and the
-- next useful action on the row below it.
function M.empty(painter: Painter, y: integer, title: string, action: string?)
    M.line(painter, y, title, painter.theme.text)
    if action and action ~= "" then M.line(painter, y + 1, action, painter.theme.muted) end
end

return M
