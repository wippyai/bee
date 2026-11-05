-- MIT. Scrolling data views over a frame painter: a table, a tree, a
-- key-value inspector and a log viewer. Each draws only its visible window
-- between rows first and last, takes the frame's row selection and hits, and
-- returns the window.
local tty = require("tty")
local appearance = require("appearance")
local frame = require("frame")
local M = {}

type Painter = frame.Painter
type Rect = frame.Rect
type Window = frame.Window
-- A table column: width 0 is flexible; flexible columns keep at least min
-- cells (default 8 or the title) and share the remaining width, and the
-- compact form applies when they cannot; align "right" for numbers.
type Column = {title: string, width: integer, align: string?, min: integer?}
-- area confines the table to a region's columns, as the list pane beside a
-- detail pane; its rows then span only that region and its marker column.
type Table = {columns: {Column}, cells: {{string}}, keys: {string}?, kind: string, selected: integer, offset: integer, focused: boolean?,
    area: Rect?}
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

local function maximum(a: integer, b: integer): integer if a > b then return a end; return b end
local function minimum(a: integer, b: integer): integer if a < b then return a end; return b end

-- Column geometry for a table at the canvas width, or nil when the flexible
-- column cannot keep at least its title width (the compact form applies).
local function column_widths(width: integer, columns: {Column}): {integer}?
    local rest, flexible = width - 2 - 2 * (#columns - 1), 0
    local widths: {integer} = {}
    for index, column in ipairs(columns) do
        widths[index] = column.width > 0 and column.width or maximum(column.min or 8, tty.text.width(column.title))
        rest = rest - widths[index]
        if column.width <= 0 then flexible = flexible + 1 end
    end
    if rest < 0 then return nil end
    local given = 0
    for index, column in ipairs(columns) do
        if column.width <= 0 then
            widths[index] = widths[index] + rest // flexible + (given < rest % flexible and 1 or 0)
            given = given + 1
        end
    end
    return widths
end

local function joined(values: {string}, widths: {integer}, columns: {Column}): string
    local parts: {string} = {}
    for index, value in ipairs(values) do
        parts[#parts + 1] = frame.pad(value, widths[index], columns[index].align)
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
    local widths = column_widths(span, value.columns)
    local captions: {string} = {}
    for index, column in ipairs(value.columns) do captions[index] = string.upper(column.title) end
    local caption = ""
    if widths then caption = joined(captions, widths, value.columns)
    else
        caption = captions[1]
        for index = 2, #captions do if captions[index] ~= "" then caption = caption .. " · " .. captions[index] end end
    end
    if area then frame.band(painter, area, first, caption, painter.theme.muted)
    else frame.line(painter, first, caption, painter.theme.muted) end
    local window = frame.window(count, last - first, value.selected, value.offset)
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
        frame.row(painter, first + slot, text, index == value.selected, value.kind, index,
            value.keys and value.keys[index] or "", nil, value.focused, nil, area)
    end
    return window
end

-- A tree view between rows first and last: only the visible window is ever
-- drawn. Each row is indented two cells per depth, then "▾" expanded, "▸"
-- collapsed, or two blank cells for a leaf, then its label; role colors the
-- label (default text). The selected row takes the row selection; every
-- drawn row carries hit kind "tree" and its key. Returns the visible window.
function M.tree(painter: Painter, first: integer, last: integer, value: TreeView): Window
    local count = #value.rows
    if last < first then return {offset = 0, capacity = 0} end
    local window = frame.window(count, last - first + 1, value.selected, value.offset)
    for slot = 1, window.capacity do
        local index = window.offset + slot
        local row = value.rows[index]
        if not row then break end
        local marker = row.expandable and (row.expanded and "▾ " or "▸ ") or "  "
        local text = string.rep("  ", maximum(0, row.depth)) .. marker .. row.label
        frame.row(painter, first + slot - 1, text, index == value.selected, "tree", index, row.key or "",
            row.role and appearance.role(painter.theme, row.role) or nil, value.focused, nil, value.area)
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
    local window = frame.window(count, last - first + 1, value.selected, value.offset)
    for slot = 1, window.capacity do
        local index = window.offset + slot
        local entry = value.entries[index]
        if not entry then break end
        local y = first + slot - 1
        local text = frame.pad(entry.label, label_width) .. "  " .. entry.value
        frame.row(painter, y, text, index == value.selected, "kv", index, entry.label,
            entry.role and appearance.role(painter.theme, entry.role) or nil, value.focused, nil, value.area)
        if index ~= value.selected then frame.put(painter, value.area and value.area.x or 2, y, frame.pad(entry.label, label_width), label_width, painter.theme.muted) end
    end
    return window
end

-- text painted at (x, y) in fg over bg, with every case-insensitive
-- occurrence of query picked out in the accent pair. A valid UTF-8 query
-- only ever matches on a UTF-8 character boundary of a valid UTF-8 text, so
-- the split never lands inside a multi-byte glyph.
local function highlighted(painter: Painter, x: integer, y: integer, text: string, room: integer, query: string?, fg: string?, bg: string?)
    if not query or query == "" or room <= 0 then frame.put(painter, x, y, text, room, fg, bg); return end
    local fitted = frame.fit(text, room)
    local haystack = fitted:lower()
    local needle = query:lower()
    local theme = painter.theme
    local column = x
    local budget = room
    local at = 1
    while budget > 0 do
        local found = haystack:find(needle, at, true)
        if not found then
            column = column + frame.put(painter, column, y, fitted:sub(at), budget, fg, bg)
            break
        end
        if found > at then
            local used = frame.put(painter, column, y, fitted:sub(at, found - 1), budget, fg, bg)
            column = column + used
            budget = budget - used
        end
        if budget <= 0 then break end
        local used = frame.put(painter, column, y, fitted:sub(found, found + #query - 1), budget, appearance.selection_text(theme), appearance.selection_background(theme))
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
    local window = frame.window(count, last - first + 1, value.selected, value.offset)
    local confined = value.area
    if confined and (confined.width <= 0 or confined.height <= 0) then return window end
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
        if selected and has_focus then fg, bg = appearance.selection_text(theme), appearance.selection_background(theme)
        elseif selected then fg = theme.accent end
        local area = value.area
        if area then
            local marker_x = maximum(1, area.x - 1)
            frame.band(painter, area, y, "", fg, bg)
            if selected and marker_x < area.x then frame.put(painter, marker_x, y, frame.MARKER, 1, fg, bg) end
            highlighted(painter, area.x, y, line.text, area.width, value.query, fg, bg)
            frame.add_hit(painter, "log", index, "", marker_x, y, area.x + area.width - marker_x, 1)
        else
            frame.fill(painter, y, bg)
            if selected then frame.put(painter, 1, y, frame.MARKER, 1, fg, bg) end
            highlighted(painter, 2, y, line.text, painter.width - 2, value.query, fg, bg)
            frame.add_hit(painter, "log", index, "", 1, y, painter.width, 1)
        end
    end
    return window
end

return M
