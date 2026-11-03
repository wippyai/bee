local tty = require("tty")

type Text = {cut: (string, integer, integer) -> string, plain: (string) -> string}
local text = tty.text

type Binding = {
    view_id: string,
    attachment: string,
    mount_generation: integer,
    width: integer,
    height: integer,
}

type Point = {x: integer, y: integer}
type Span = {start: Point, finish: Point}
type Snapshot = {binding: Binding, rows: {string}}
-- lines widens the range to whole rows, as a line-wise selection does.
type State = {snapshot: Snapshot, anchor: Point?, focus: Point?, dragging: boolean, lines: boolean}

local MAX_VIEWPORT_CELLS: integer = 262144
local MAX_SNAPSHOT_BYTES: integer = 2 * 1024 * 1024
local MAX_VIEWPORT_DIMENSION: integer = 65535

local M = {}

local function copy_binding(value: Binding): Binding
    return {view_id = value.view_id, attachment = value.attachment, mount_generation = value.mount_generation,
        width = value.width, height = value.height}
end

local function copy_rows(rows: {string}): {string}
    local copy: {string} = {}
    for index, row in ipairs(rows) do copy[index] = row end
    return copy
end

local function copy_point(point: Point?): Point?
    if not point then return nil end
    return {x = point.x, y = point.y}
end

local function copy_state(value: State, anchor: Point?, focus: Point?, dragging: boolean, lines: boolean?): State
    -- Strings are immutable and this snapshot was copied during capture. Drag
    -- updates must not recopy a full viewport for every pointer motion.
    local line_wise = value.lines
    if lines ~= nil then line_wise = lines end
    return {snapshot = value.snapshot, anchor = copy_point(anchor), focus = copy_point(focus), dragging = dragging,
        lines = line_wise}
end

local function point(value: State, x: integer, y: integer): Point
    local binding = value.snapshot.binding
    local clipped_x: integer = math.floor(math.max(1, math.min(binding.width, x)))
    local clipped_y: integer = math.floor(math.max(1, math.min(binding.height, y)))
    return {x = clipped_x, y = clipped_y}
end

local function before_or_equal(left: Point, right: Point): boolean
    return left.y < right.y or (left.y == right.y and left.x <= right.x)
end

local function binding_valid(value: Binding): boolean
    return value.view_id ~= "" and value.attachment ~= "" and value.mount_generation >= 0
        and value.width >= 1 and value.width <= MAX_VIEWPORT_DIMENSION
        and value.height >= 1 and value.height <= MAX_VIEWPORT_DIMENSION
        and value.width * value.height <= MAX_VIEWPORT_CELLS
end

function M.capture(binding: Binding, rows: {string}): (State?, string?)
    if not binding_valid(binding) then return nil, "Selection geometry or identity is out of bounds" end
    if #rows ~= binding.height then return nil, "Viewport rows do not match selection geometry" end

    -- Reserve separators too, so an extracted multiline value remains bounded.
    local bytes = 0
    local maximum_raw_bytes = MAX_SNAPSHOT_BYTES - binding.height + 1
    for index = 1, binding.height do
        local row = rows[index]
        if type(row) ~= "string" then return nil, "Viewport row is not text" end
        bytes = bytes + #row
        if bytes > maximum_raw_bytes then return nil, "Viewport snapshot is too large" end
        if tty.text.width(row) > binding.width then return nil, "Viewport row exceeds selection geometry" end
    end

    return {snapshot = {binding = copy_binding(binding), rows = copy_rows(rows)}, anchor = nil, focus = nil, dragging = false,
        lines = false}, nil
end

function M.active(value: State?): boolean return value ~= nil end

function M.cancel(_: State?): State? return nil end

function M.valid(value: State?, binding: Binding): boolean
    if not value or not binding_valid(binding) then return false end
    local captured = value.snapshot.binding
    return captured.view_id == binding.view_id and captured.attachment == binding.attachment
        and captured.mount_generation == binding.mount_generation
        and captured.width == binding.width and captured.height == binding.height
end

-- Validation runs for every pointer event. Copy only the small identity record;
-- callers that need rows use snapshot(), which intentionally copies them.
function M.binding(value: State): Binding
    return copy_binding(value.snapshot.binding)
end

function M.snapshot(value: State): Snapshot
    return {binding = copy_binding(value.snapshot.binding), rows = copy_rows(value.snapshot.rows)}
end

function M.press(value: State, x: integer, y: integer): State
    -- A later press begins a fresh range in the same explicit selection mode.
    local pressed = point(value, x, y)
    return copy_state(value, pressed, pressed, true)
end

function M.drag(value: State, x: integer, y: integer): State
    if not value.anchor then return copy_state(value, nil, nil, value.dragging) end
    return copy_state(value, value.anchor, point(value, x, y), value.dragging)
end

-- dragging is whether a press began a range the pointer still moves.
function M.dragging(value: State): boolean return value.dragging end

function M.motion(value: State, x: integer, y: integer): State
    if not value.dragging then return value end
    return M.drag(value, x, y)
end

function M.release(value: State, x: integer, y: integer): State
    if not value.dragging then return value end
    local moved = M.drag(value, x, y)
    return copy_state(moved, moved.anchor, moved.focus, false)
end

-- whole_cells widens the cell interval [first, last) of row to whole
-- characters: a wide character the selection only partly covers is taken
-- whole, as a terminal selects it. text.cut keeps only characters wholly
-- inside its range, so the width of the cut before a cell shows where the
-- character covering that cell starts.
local function whole_cells(row: string, first: integer, last: integer, width: integer): (integer, integer)
    local start = text.width(text.cut(row, 0, first))
    local finish = last
    while finish < width and text.width(text.cut(row, 0, finish)) < finish do finish = finish + 1 end
    return start, finish
end

function M.range(value: State): Span?
    local anchor, focus = value.anchor, value.focus
    if not anchor or not focus then return nil end
    local first, last = anchor, focus
    if not before_or_equal(anchor, focus) then first, last = focus, anchor end
    if value.lines then
        return {start = {x = 1, y = first.y}, finish = {x = value.snapshot.binding.width, y = last.y}}
    end
    return {start = {x = first.x, y = first.y}, finish = {x = last.x, y = last.y}}
end

-- span selects from anchor to focus, both clamped to the snapshot; lines
-- makes the selection line-wise.
function M.span(value: State, anchor: Point, focus: Point, lines: boolean): State
    return copy_state(value, point(value, anchor.x, anchor.y), point(value, focus.x, focus.y), false, lines)
end

-- clear drops the range and keeps the snapshot.
function M.clear(value: State): State
    return copy_state(value, nil, nil, false, false)
end

function M.width(value: State): integer return value.snapshot.binding.width end
function M.height(value: State): integer return value.snapshot.binding.height end

-- plain is row y of the snapshot without styling.
function M.plain(value: State, y: integer): string
    return text.plain(value.snapshot.rows[y] or "")
end

-- WORD_BREAK holds the characters that end a word for a double click, so a
-- path, URL or id selects whole while brackets and quotes around it stay out.
local WORD_BREAK = "[%s\"'`()%[%]{}<>,;|]"

-- cell_text is the character covering cell x of row y, or "" past the row.
local function cell_text(value: State, x: integer, y: integer): string
    local row = value.snapshot.rows[y] or ""
    local first, last = whole_cells(row, x - 1, x, value.snapshot.binding.width)
    return text.plain(text.cut(row, first, last))
end

local function word_cell(value: State, x: integer, y: integer): boolean
    local found = cell_text(value, x, y)
    return found ~= "" and not found:find(WORD_BREAK)
end

-- word selects the word covering cell x of row y; a cell between words
-- selects only itself.
function M.word(value: State, x: integer, y: integer): State
    local at = point(value, x, y)
    if not word_cell(value, at.x, at.y) then return M.span(value, at, at, false) end
    local first, last = at.x, at.x
    while first > 1 and word_cell(value, first - 1, at.y) do first = first - 1 end
    while last < value.snapshot.binding.width and word_cell(value, last + 1, at.y) do last = last + 1 end
    return M.span(value, {x = first, y = at.y}, {x = last, y = at.y}, false)
end

-- line selects row y whole.
function M.line(value: State, y: integer): State
    local at = point(value, 1, y)
    return M.span(value, at, at, true)
end

-- cell is the first cell of byte offset index in plain row text.
local function cell(row: string, index: integer): integer
    return text.width(row:sub(1, index - 1)) + 1
end

-- find returns the cell where the next match of query starts after from, or
-- before it when step is -1, wrapping around the snapshot. A query without
-- capitals matches case-insensitively.
function M.find(value: State, query: string, from: Point, step: integer): Point?
    if query == "" then return nil end
    local folded = query:lower() == query
    local height = value.snapshot.binding.height
    local matches: {Point} = {}
    for y = 1, height do
        local row = M.plain(value, y)
        if folded then row = row:lower() end
        local index = row:find(query, 1, true)
        while index do
            matches[#matches + 1] = {x = cell(row, index), y = y}
            index = row:find(query, index + 1, true)
        end
    end
    if #matches == 0 then return nil end
    if step < 0 then
        for index = #matches, 1, -1 do
            if before_or_equal(matches[index], from) and not (matches[index].x == from.x and matches[index].y == from.y) then return matches[index] end
        end
        return matches[#matches]
    end
    for _, found in ipairs(matches) do
        if not before_or_equal(found, from) then return found end
    end
    return matches[1]
end

function M.text(value: State): (string?, string?)
    local span = M.range(value)
    if not span then return nil end

    local rows = value.snapshot.rows
    local width = value.snapshot.binding.width
    local parts: {string} = {}
    local output_bytes = 0
    for y = span.start.y, span.finish.y do
        local first = y == span.start.y and span.start.x - 1 or 0
        local last = y == span.finish.y and span.finish.x or width
        first, last = whole_cells(rows[y], first, last, width)
        local part = (text.plain(text.cut(rows[y], first, last)):gsub("%s+$", ""))
        output_bytes = output_bytes + #part + (y == span.start.y and 0 or 1)
        if output_bytes > MAX_SNAPSHOT_BYTES then return nil, "Selected text is too large" end
        parts[#parts + 1] = part
    end
    return table.concat(parts, "\n"), nil
end

return M
