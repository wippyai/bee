-- MIT. The shared application frame: one header, tabs, one action and
-- key-hint footer, scrolling rows, layout regions, documents, cards and an
-- empty or error state, all drawn from semantic appearance roles. Pure: it
-- paints one canvas and records hit rectangles. bee.ui:lists draws tables,
-- trees, inspectors and logs on its painter; bee.ui:overlay draws the More,
-- Help and row-action overlay over its views and routes their input.
--
-- Anatomy: header, optional tabs, work and one footer with actions and hints.
local tty = require("tty")
local appearance = require("appearance")
local M = {}
local RESET = "\27[0m"
local ELLIPSIS = "…"
local MARKER = "›"
-- MARKER is the glyph in column 1 that marks a selected row.
M.MARKER = MARKER

type Hit = {kind: string, index: integer, key: string, x: integer, y: integer, width: integer, height: integer}
-- A button with a key is drawn as "Key Label"; primary marks the one filled
-- action, active a selected toggle. Disabled buttons stay visible and have no hit.
-- tab marks a tab of the screen's tab row.
type Button = {kind: string, label: string, enabled: boolean, primary: boolean?, active: boolean?, key: string?, more: boolean?, tab: boolean?}
type Tab = {kind: string, label: string, short: string?}
type Hint = {key: string, verb: string}
-- The actions one row offers; selected marks the row Shift+F10 opens.
-- select is the target kind a right click presses to select the row
-- (default kind), for rows whose own press also activates them.
type RowActions = {kind: string, index: integer, key: string, actions: {Button}, selected: boolean?, select: string?}
type Controls = {buttons: {Button}, overflow: {Button}, hints: {Hint}, status: string?, rows: {RowActions}}
type Bar = {x: integer, buttons: {Button}}
type Painter = {width: integer, height: integer, theme: appearance.Theme, canvas: tty.Canvas, hits: {Hit}, controls: Controls, bars: {[integer]: Bar}}
type View = {rows: {string}, hits: {Hit}, controls: Controls?}

type Window = {offset: integer, capacity: integer}
type ListCard = {glyph: string, title: string, requester: string, summary: string, meta: string}
-- A cell rectangle: x and y are one-based, width and height may be zero.
type Rect = {x: integer, y: integer, width: integer, height: integer}
-- The rows of the canonical anatomy; tabs and actions are 0 when absent.
type Layout = {size: string, tabs: integer, work: Rect, actions: integer, footer: integer}
-- One toast notification, drawn in role's color (default accent).
type Toast = {text: string, role: string?}

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

-- tagged is a row's text with a tag aligned to the right edge of width cells;
-- the text gives way when both do not fit.
function M.tagged(width: integer, value: string, tag: string): string
    local room = maximum(0, width - 3)
    if tag == "" then return M.fit(value, room) end
    local tag_text = M.fit(tag, room // 2)
    local text_room = maximum(0, room - tty.text.width(tag_text) - 2)
    return M.pad(value, text_room) .. "  " .. tag_text
end

-- A painter over a canvas cleared to the theme's surface, with no hits yet.
function M.new(width: integer, height: integer, preferences: appearance.Preferences): Painter
    local theme = preferences.theme
    local canvas = tty.canvas(maximum(1, width), maximum(1, height))
    canvas:clear(appearance.style(theme.text, theme.surface) .. " " .. RESET)
    local controls: Controls = {buttons = {}, overflow = {}, hints = {}, status = "", rows = {}}
    local bars: {[integer]: Bar} = {}
    return {width = width, height = height, theme = theme, canvas = canvas, hits = {}, controls = controls, bars = bars}
end

-- The painted rows, ready for output:present.
function M.rows(painter: Painter, background: string?): {string}
    for y, bar in pairs(painter.bars) do M.actions(painter, y, bar.buttons, bar.x) end
    painter.bars = {}
    local painted = painter.canvas:rows()
    local rows: {string} = {}
    for y = 1, painter.height do
        local row = painted[y] or ""
        local gap = maximum(0, painter.width - tty.text.width(row))
        rows[y] = row .. appearance.style(painter.theme.text, background or painter.theme.surface) .. string.rep(" ", gap) .. RESET
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

-- A tab row. Inactive labels switch to their short form when the full set
-- does not fit. Returns the column after the last drawn tab.
function M.tabs(painter: Painter, y: integer, tabs: {Tab}, selected: string): integer
    for _, tab in ipairs(tabs) do
        painter.controls.buttons[#painter.controls.buttons + 1] = {kind = tab.kind, label = tab.label, enabled = true, tab = true}
    end
    -- The active tab keeps its full label and inactive tabs that do not
    -- fit are left out, so the pane shown stays named at any width.
    local full = 1
    for _, tab in ipairs(tabs) do full = full + tty.text.width(" " .. tab.label .. " ") + 1 end
    local compact = full > painter.width
    local function label_of(tab: Tab): string
        return " " .. ((compact and tab.kind ~= selected and tab.short) or tab.label) .. " "
    end
    local reserved = 0
    for _, tab in ipairs(tabs) do
        if tab.kind == selected then reserved = tty.text.width(label_of(tab)) + 1 end
    end
    local theme = painter.theme
    local x = 2
    for index, tab in ipairs(tabs) do
        local active = tab.kind == selected
        local label = label_of(tab)
        local size = tty.text.width(label)
        local room = painter.width - x + 1 - (active and 0 or reserved)
        if size <= room then
            M.put(painter, x, y, label, size, active and appearance.selection_text(theme) or theme.muted,
                active and appearance.selection_background(theme) or theme.surface)
            M.add_hit(painter, tab.kind, index, "", x, y, size, 1)
            x = x + size + 1
            if active then reserved = 0 end
        end
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
        if button.primary or button.active then fg, bg = appearance.selection_text(theme), appearance.selection_background(theme)
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
    local forced = false
    for _, button in ipairs(buttons) do
        total = total + button_width(button)
        if button.more then forced = true end
        painter.controls.buttons[#painter.controls.buttons + 1] = button
    end
    local room = painter.width - column
    if not forced and total - 1 <= room then
        for _, button in ipairs(buttons) do column = draw_button(painter, column, y, button) end
        return column
    end
    local more: Button = {kind = "frame_more", key = "F10", label = "More", enabled = true}
    local reserve = button_width(more)
    for _, button in ipairs(buttons) do
        if button.primary and not button.more and button_width(button) + reserve > room then
            more = {kind = "frame_more", label = "More", enabled = true}
            reserve = button_width(more)
            break
        end
    end
    local available = room - reserve
    local chosen: {[integer]: boolean} = {}
    for _, primary in ipairs({true, false}) do
        for index, button in ipairs(buttons) do
            if not button.more and (button.primary == true) == primary and button_width(button) <= available then
                chosen[index] = true
                available = available - button_width(button)
            end
        end
    end
    for index, button in ipairs(buttons) do
        if chosen[index] then column = draw_button(painter, column, y, button)
        else painter.controls.overflow[#painter.controls.overflow + 1] = button end
    end
    if reserve > 0 then return draw_button(painter, column, y, more) end
    return column
end

-- Canonical key-hint text: "↑↓ select · Enter open · Esc close".
function M.hints(hints: {Hint}): string
    local parts: {string} = {}
    for _, hint in ipairs(hints) do parts[#parts + 1] = hint.key .. " " .. hint.verb end
    return table.concat(parts, " · ")
end

function M.footer(painter: Painter, status: string, hints: string, more: string?, buttons: {Button}?)
    local y = painter.height
    painter.controls.status = status
    if y < 1 then return end
    local actions = buttons or {}
    if #painter.controls.rows > 0 then hints = hints ~= "" and ("Shift+F10 actions · " .. hints) or "Shift+F10 actions" end
    local listed = hints
    if more and more ~= "" then listed = hints .. " · " .. more end
    for part in listed:gmatch("[^·]+") do
        local key, verb = part:match("^%s*(%S+)%s+(.+)%s*$")
        if key and verb then painter.controls.hints[#painter.controls.hints + 1] = {key = key, verb = verb:gsub("%s+$", "")} end
    end
    M.fill(painter, y)
    local column = M.actions(painter, y, actions)
    local room = maximum(0, painter.width - column - 1)
    local shown: {string} = {}
    local used = 0
    for part in hints:gmatch("[^·]+") do
        local item = part:match("^%s*(.-)%s*$") or ""
        local key = item:match("^(%S+)")
        local duplicate = key == "?"
        for _, button in ipairs(actions) do
            if button.key and key and button.key:lower() == key:lower() then
                for _, hit in ipairs(painter.hits) do
                    if hit.kind == button.kind and hit.y == y then duplicate = true end
                end
            end
        end
        local size = tty.text.width(item)
        if not duplicate and size + used + (used > 0 and 3 or 0) + 9 <= room then
            shown[#shown + 1] = item
            used = used + size + (used > 0 and 3 or 0)
        end
    end
    if room >= 6 then shown[#shown + 1] = "? help" end
    local value = table.concat(shown, " · ")
    local size = tty.text.width(value)
    local x = painter.width - size
    if size > 0 then
        M.put(painter, x, y, value, size, painter.theme.muted)
        M.add_hit(painter, "frame_help", 0, "", painter.width - 6, y, 6, 1)
    end
    if status ~= "" then M.line(painter, y - 1, status, painter.theme.muted) end
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
function M.band(painter: Painter, area: Rect, y: integer, value: string, fg: string?, bg: string?)
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
    if selected and has_focus then text_fg, bg = appearance.selection_text(theme), appearance.selection_background(theme)
    elseif selected then text_fg = theme.accent end
    if area then
        local x = maximum(1, area.x - 1)
        M.band(painter, area, y, value, text_fg, bg)
        if selected and x < area.x then M.put(painter, x, y, MARKER, 1, text_fg, bg) end
        M.add_hit(painter, kind, index, key, x, y, area.x + area.width - x, span or 1)
        return
    end
    M.line(painter, y, value, text_fg, bg)
    if selected then M.put(painter, 1, y, MARKER, 1, text_fg, bg) end
    M.add_hit(painter, kind, index, key, 1, y, painter.width, span or 1)
end

function M.row(painter: Painter, y: integer, value: string, selected: boolean, kind: string, index: integer, key: string, fg: string?, focused: boolean?, span: integer?, area: Rect?)
    draw_row(painter, area, y, value, selected, kind, index, key, fg, focused, span)
end

function M.list_card(painter: Painter, y: integer, height: integer, value: ListCard, selected: boolean, kind: string, index: integer, key: string)
    local theme = painter.theme
    local fg = selected and appearance.selection_text(theme) or theme.text
    local bg = selected and appearance.selection_background(theme) or theme.surface
    local muted = selected and fg or theme.muted
    for line = 0, height - 1 do M.line(painter, y + line, "", fg, bg) end
    if selected then M.put(painter, 1, y, MARKER, 1, fg, bg) end
    M.put(painter, 2, y, value.glyph, 1, fg, bg)
    local room = maximum(0, painter.width - 5)
    local requester = M.fit(value.requester, room // 3)
    local tag_width = tty.text.width(requester)
    local title_room = maximum(0, room - tag_width - 2)
    local title = M.fit(value.title, title_room)
    if title ~= "" then painter.canvas:put(4, y, appearance.style(fg, bg) .. "\27[1m" .. title .. RESET, tty.text.width(title)) end
    M.put(painter, painter.width - tag_width, y, requester, tag_width, muted, bg)
    if height >= 3 then
        M.put(painter, 2, y + 1, "│", 1, muted, bg)
        M.put(painter, 4, y + 1, value.summary, room, fg, bg)
    end
    if height >= 2 then
        M.put(painter, 2, y + height - 1, "└", 1, muted, bg)
        M.put(painter, 4, y + height - 1, value.meta, room, muted, bg)
    end
    M.add_hit(painter, kind, index, key, 1, y, painter.width, height)
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
-- final row when requested and the canvas has at least 6 rows, and the
-- footer on the final row when the canvas has at least 2 rows.
function M.layout(painter: Painter, tabs: boolean, actions: boolean): Layout
    local height = painter.height
    local roomy = height >= 6
    local tab_row = (tabs and roomy) and 2 or 0
    local action_row = (actions and roomy) and height or 0
    local footer_row = height >= 2 and height or 0
    local first = roomy and (tab_row > 0 and 4 or 3) or 2
    local last = footer_row > 0 and footer_row - 1 or height
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

-- A section heading on row y: the uppercase title in accent and an optional
-- muted summary aligned right, within area's columns (default the content
-- columns). The summary is truncated first and omitted when fewer than four
-- cells remain.
function M.section(painter: Painter, y: integer, title: string, summary: string?, area: Rect?)
    local x = area and area.x or 2
    local room = area and area.width or painter.width - 2
    if room <= 0 or y < 1 or y > painter.height then return end
    painter.canvas:put(x, y, appearance.style(painter.theme.text, painter.theme.surface) .. string.rep(" ", minimum(room, painter.width - x + 1)) .. RESET,
        minimum(room, painter.width - x + 1))
    local drawn = M.put(painter, x, y, string.upper(title), room, painter.theme.accent)
    if not summary or summary == "" then return end
    local free = room - drawn - 2
    if free < 4 then return end
    local shown = M.fit(summary, free)
    local size = tty.text.width(shown)
    M.put(painter, x + room - size, y, shown, size, painter.theme.muted)
end

-- A titled panel without a border: a section heading at the top of rect and
-- the returned rectangle below it for the panel's content.
function M.panel(painter: Painter, rect: Rect, title: string, summary: string?): Rect
    if rect.width <= 0 or rect.height <= 0 then return {x = rect.x, y = rect.y, width = 0, height = 0} end
    M.section(painter, rect.y, title, summary, rect)
    return {x = rect.x, y = rect.y + 1, width = rect.width, height = rect.height - 1}
end

-- One document line: a section heading with an optional summary, a field
-- (label, then value), a text line (value only) or a gap (neither). role and
-- label_role name appearance roles.
type Line = {heading: string?, summary: string?, label: string?, value: string?, role: string?, label_role: string?}

-- Splits value into pieces of at most room display cells.
local function pieces(value: string, room: integer): {string}
    local parts: {string} = {}
    local remaining = value:gsub("[%z\1-\31\127]", " ")
    while room > 0 and tty.text.width(remaining) > room do
        local part = tty.text.truncate(remaining, room, "")
        if part == "" then break end
        parts[#parts + 1] = part
        remaining = remaining:sub(#part + 1)
    end
    parts[#parts + 1] = remaining
    return parts
end

-- Lines under a document's headings are indented by this many cells.
local INDENT = 2

-- The lines of a document laid out for width: a field's value wraps under
-- its value column, or under its label indented by two cells when the value
-- column would be narrower than eight cells; a text line wraps within width.
function M.flow(lines: {Line}, width: integer, label_width: integer): {Line}
    local laid: {Line} = {}
    local room = maximum(1, width - INDENT)
    for _, line in ipairs(lines) do
        if line.label then
            local column = room - label_width - 2
            if column < 8 then
                laid[#laid + 1] = {label = line.label, value = "", role = line.role, label_role = line.label_role}
                for _, part in ipairs(pieces(line.value or "", maximum(1, room - 2))) do
                    laid[#laid + 1] = {value = "  " .. part, role = line.role}
                end
            else
                for index, part in ipairs(pieces(line.value or "", column)) do
                    laid[#laid + 1] = {label = index == 1 and line.label or "", value = part, role = line.role, label_role = line.label_role}
                end
            end
        elseif line.value and not line.heading then
            for _, part in ipairs(pieces(line.value, room)) do laid[#laid + 1] = {value = part, role = line.role} end
        else
            laid[#laid + 1] = line
        end
    end
    return laid
end

-- A sectioned document between rows first and last, from offset: headings as
-- sections and, indented under them, fields as a muted label padded to
-- label_width then the value in role (default text), text lines in role and
-- gaps. area confines it to a region's columns. Returns the visible window.
function M.document(painter: Painter, first: integer, last: integer, lines: {Line}, offset: integer, label_width: integer, area: Rect?): Window
    if last < first then return {offset = 0, capacity = 0} end
    local window = M.window(#lines, last - first + 1, 0, offset)
    local x = (area and area.x or 2) + INDENT
    local room = (area and area.width or painter.width - 2) - INDENT
    local theme = painter.theme
    for slot = 1, window.capacity do
        local line = lines[window.offset + slot]
        if not line then break end
        local y = first + slot - 1
        local fg = line.role and appearance.role(theme, line.role) or theme.text
        if line.heading then M.section(painter, y, line.heading, line.summary, area)
        elseif line.label then
            local size = minimum(label_width, room)
            M.put(painter, x, y, M.pad(line.label, size), size, line.label_role and appearance.role(theme, line.label_role) or theme.muted)
            M.put(painter, x + size + 2, y, line.value or "", room - size - 2, fg)
        elseif line.value then M.put(painter, x, y, line.value, room, fg) end
    end
    return window
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
            painter.width - 2, appearance.selection_text(theme), appearance.selection_background(theme))
        return
    end
    local x = 2
    for index, part in ipairs(parts) do
        if index > 1 then x = x + M.put(painter, x, y, " › ", 3, theme.muted) end
        local label = " " .. part .. " "
        if index == current then x = x + M.put(painter, x, y, label, painter.width - x, appearance.selection_text(theme), appearance.selection_background(theme))
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

-- A status badge at (x, y): text padded with one cell on each side, filled
-- in role's color (default accent) with a contrasting foreground. Returns
-- the drawn width.
function M.badge(painter: Painter, x: integer, y: integer, text: string, role: string?): integer
    local label = " " .. text .. " "
    local size = tty.text.width(label)
    local bg = appearance.selection_background(painter.theme, appearance.role(painter.theme, role or "accent"))
    return M.put(painter, x, y, label, size, appearance.selection_text(painter.theme), bg)
end

-- A one-row toast notification: the message centered on row y, filled in
-- role's color (default accent) with a contrasting foreground, overwriting
-- whatever was on that row. The caller owns when a toast is shown and for
-- how long; this only draws the row.
function M.toast(painter: Painter, y: integer, toast: Toast)
    if y < 1 or y > painter.height then return end
    local bg = appearance.selection_background(painter.theme, appearance.role(painter.theme, toast.role or "accent"))
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

-- Declares the actions a row offers: a right click on the row's target
-- (kind, index, key) or Shift+F10 on the selected row opens them as a popup
-- menu; a right click also reaches the app as a press on the row's select
-- target, so the app selects the row without activating it. Each action is a Button; choosing one reaches the app as a press on
-- a target of the action's kind carrying the row's index and key.
function M.row_actions(painter: Painter, row: RowActions)
    painter.controls.rows[#painter.controls.rows + 1] = row
end

return M
