local tty = require("tty")

type Text = {cut: (string, integer, integer) -> string, plain: (string) -> string}
local text = tty.text :: Text

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
type State = {snapshot: Snapshot, anchor: Point?, focus: Point?, dragging: boolean}

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

local function copy_state(value: State, anchor: Point?, focus: Point?, dragging: boolean): State
    -- Strings are immutable and this snapshot was copied during capture. Drag
    -- updates must not recopy a full viewport for every pointer motion.
    return {snapshot = value.snapshot, anchor = copy_point(anchor), focus = copy_point(focus), dragging = dragging}
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

    return {snapshot = {binding = copy_binding(binding), rows = copy_rows(rows)}, anchor = nil, focus = nil, dragging = false}, nil
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

function M.motion(value: State, x: integer, y: integer): State
    if not value.dragging then return value end
    return M.drag(value, x, y)
end

function M.release(value: State, x: integer, y: integer): State
    if not value.dragging then return value end
    local moved = M.drag(value, x, y)
    return copy_state(moved, moved.anchor, moved.focus, false)
end

function M.range(value: State): Span?
    local anchor, focus = value.anchor, value.focus
    if not anchor or not focus then return nil end
    if before_or_equal(anchor, focus) then
        return {start = {x = anchor.x, y = anchor.y}, finish = {x = focus.x, y = focus.y}}
    end
    return {start = {x = focus.x, y = focus.y}, finish = {x = anchor.x, y = anchor.y}}
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
        -- Native helpers retain terminal cell semantics and remove controls safely.
        local part = text.plain(text.cut(rows[y], first, last))
        output_bytes = output_bytes + #part + (y == span.start.y and 0 or 1)
        if output_bytes > MAX_SNAPSHOT_BYTES then return nil, "Selected text is too large" end
        parts[#parts + 1] = part
    end
    return table.concat(parts, "\n"), nil
end

return M
