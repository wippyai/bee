-- MIT. Layout diagrams that are not time series or a layered flow: a mesh of
-- nodes at arbitrary positions with braille-routed edges, a proportional
-- treemap of sized items and an icicle (flame) chart of a value tree. Pure:
-- every drawing function paints inside the rectangle it is given through the
-- application frame, reads colors from semantic roles and keeps no state
-- between frames. `bee.application:viz` still owns the layered node-edge
-- graph (`viz.graph`); this module is for the diagrams that graph does not
-- shape, sharing its node and edge vocabulary where they overlap.
local tty = require("tty")
local appearance = require("appearance")
local frame = require("frame")
local viz = require("viz")
local M = {}

-- The most nodes and edges one mesh lays out; the rest are not drawn.
M.MESH_NODES = 48
M.MESH_EDGES = 128
-- The most items one treemap lays out; the rest are not drawn.
M.TREEMAP_ITEMS = 48

type Rect = frame.Rect
-- A mesh node. x and y are fractions of the rect (0 left/top, 1 right/
-- bottom); a node without them is placed evenly on a ring around the rect's
-- center, in input order.
type MeshNode = {id: string, label: string, role: string?, note: string?, x: number?, y: number?}
type MeshEdge = {from: string, to: string, role: string?}
-- One value tree node for an icicle chart: value is this frame's own share
-- of its parent's width; children need not sum to it, the remainder stays
-- blank (self time, or an unaccounted remainder).
type Frame = {label: string, value: number, role: string?, children: {Frame}?}

local function maximum(a: integer, b: integer): integer if a > b then return a end; return b end
local function minimum(a: integer, b: integer): integer if a < b then return a end; return b end
local function clamp(value: integer, low: integer, high: integer): integer return maximum(low, minimum(high, value)) end
local function round(value: number): integer return math.floor(value + 0.5) end
local function color(painter: frame.Painter, role: string?, fallback: string): string
    return appearance.role(painter.theme, role or fallback)
end

local STACK_ROLES: {string} = {"accent", "text", "muted", "border"}

-- Braille dot bits for (column 0..1, row 0..3 from the top), as in viz.
local DOTS: {{integer}} = {{0x01, 0x02, 0x04, 0x40}, {0x08, 0x10, 0x20, 0x80}}
local function braille(bits: integer): string
    return string.char(0xE2, 0xA0 + bits // 64, 0x80 + bits % 64)
end

-- A network or mesh map: each node is "● label" at its given fractional
-- position, or spread evenly on a ring when it has none, with an optional
-- muted note on the row below when the node's own row and the one under it
-- are both free of other nodes. Edges are undirected braille dot lines in
-- their role (default border) between node centers, routed straight and
-- never drawn over a node's own cell. Nodes record "node" hits of their
-- index and id. Returns the number of nodes drawn.
function M.mesh(painter: frame.Painter, rect: Rect, nodes: {MeshNode}, edges: {MeshEdge}): integer
    if rect.width <= 0 or rect.height <= 0 then return 0 end
    local count = minimum(#nodes, M.MESH_NODES)
    if count == 0 then return 0 end
    local index_of: {[string]: integer} = {}
    for index = 1, count do index_of[nodes[index].id] = index end
    local cx: {integer} = {}
    local cy: {integer} = {}
    for index = 1, count do
        local node = nodes[index]
        if node.x ~= nil and node.y ~= nil then
            cx[index] = rect.x + clamp(round(node.x * (rect.width - 1)), 0, rect.width - 1)
            cy[index] = rect.y + clamp(round(node.y * (rect.height - 1)), 0, rect.height - 1)
        else
            local angle = (index - 1) / count * math.pi * 2
            local rx = (rect.width - 1) // 2
            local ry = (rect.height - 1) // 2
            cx[index] = rect.x + rx + round(math.sin(angle) * rx)
            cy[index] = rect.y + ry - round(math.cos(angle) * ry)
        end
    end
    local occupied: {[integer]: boolean} = {}
    local function cell(x: integer, y: integer): integer return y * 4096 + x end
    local with_notes = false
    for index = 1, count do if nodes[index].note and nodes[index].note ~= "" then with_notes = true end end
    for index = 1, count do
        occupied[cell(cx[index], cy[index])] = true
        local room = maximum(0, rect.x + rect.width - (cx[index] + 2))
        local label_len = minimum(room, tty.text.width(nodes[index].label))
        for offset = 1, 1 + label_len do occupied[cell(cx[index] + offset, cy[index])] = true end
        if with_notes and cy[index] + 1 <= rect.y + rect.height - 1 then
            local note_len = minimum(room, tty.text.width(nodes[index].note or ""))
            for offset = 0, maximum(0, note_len - 1) do occupied[cell(cx[index] + 2 + offset, cy[index] + 1)] = true end
            occupied[cell(cx[index], cy[index] + 1)] = true
            occupied[cell(cx[index] + 1, cy[index] + 1)] = true
        end
    end
    local cells: {[integer]: integer} = {}
    local fgs: {[integer]: string} = {}
    for position, edge in ipairs(edges) do
        if position > M.MESH_EDGES then break end
        local from = index_of[edge.from]
        local to = index_of[edge.to]
        if from and to and from ~= to then
            local fg = color(painter, edge.role, "border")
            local x0, y0 = (cx[from] - rect.x) * 2, (cy[from] - rect.y) * 4 + 2
            local x1, y1 = (cx[to] - rect.x) * 2, (cy[to] - rect.y) * 4 + 2
            local dx = math.abs(x1 - x0)
            local dy = -math.abs(y1 - y0)
            local sx = x0 < x1 and 1 or -1
            local sy = y0 < y1 and 1 or -1
            local err = dx + dy
            local x, y = x0, y0
            while true do
                local ownerx, ownery = rect.x + x // 2, rect.y + y // 4
                if not occupied[cell(ownerx, ownery)] then
                    local key = cell(ownerx, ownery)
                    cells[key] = (cells[key] or 0) | DOTS[x % 2 + 1][y % 4 + 1]
                    fgs[key] = fg
                end
                if x == x1 and y == y1 then break end
                local e2 = err * 2
                if e2 >= dy then err = err + dy; x = x + sx end
                if e2 <= dx then err = err + dx; y = y + sy end
            end
        end
    end
    for key, bits in pairs(cells) do
        frame.clip(painter, key % 4096, key // 4096, braille(bits), 1, fgs[key])
    end
    for index = 1, count do
        local node = nodes[index]
        frame.clip(painter, cx[index], cy[index], "●", 1, color(painter, node.role, "accent"))
        frame.put(painter, cx[index] + 2, cy[index], node.label, rect.x + rect.width - (cx[index] + 2))
        if with_notes and node.note and node.note ~= "" and cy[index] + 1 <= rect.y + rect.height - 1 then
            frame.put(painter, cx[index] + 2, cy[index] + 1, node.note or "", rect.x + rect.width - (cx[index] + 2), painter.theme.muted)
        end
        frame.add_hit(painter, "node", index, node.id, cx[index], cy[index], minimum(2 + tty.text.width(node.label), rect.x + rect.width - cx[index]),
            minimum(with_notes and 2 or 1, rect.y + rect.height - cy[index]))
    end
    return count
end

local function worst(row: {number}, side: number): number
    if #row == 0 or side <= 0 then return math.huge end
    local sum, high, low = 0, -1 / 0, 1 / 0
    for _, area in ipairs(row) do
        sum = sum + area
        if area > high then high = area end
        if area < low then low = area end
    end
    if sum <= 0 then return math.huge end
    local side2 = side * side
    local a = (side2 * high) / (sum * sum)
    local b = (sum * sum) / (side2 * low)
    return a > b and a or b
end

-- A squarified treemap: each item's area is its share of value over the sum
-- of positive values, tiled to keep rectangles close to square. Each tile is
-- filled with its role mixed into the surface, the label at its top-left and
-- the formatted value at its bottom-right when they fit, and records a
-- "tile" hit of its index. Non-positive values are skipped. Returns the
-- number of tiles drawn.
function M.treemap(painter: frame.Painter, rect: Rect, items: {viz.Bar}, unit: string?): integer
    if rect.width <= 0 or rect.height <= 0 or #items == 0 then return 0 end
    local order: {integer} = {}
    local total = 0
    for index, item in ipairs(items) do
        if index <= M.TREEMAP_ITEMS and item.value > 0 then order[#order + 1] = index; total = total + item.value end
    end
    if total <= 0 then return 0 end
    table.sort(order, function(a: integer, b: integer): boolean return items[a].value > items[b].value end)
    local areas: {[integer]: number} = {}
    local area_total = rect.width * rect.height
    for _, index in ipairs(order) do areas[index] = items[index].value / total * area_total end
    local function area_of(index: integer): number return areas[index] or 0 end
    local placed: {[integer]: Rect} = {}
    local pending = order
    local px, py, pw, ph = rect.x, rect.y, rect.width, rect.height
    while #pending > 0 and pw > 0 and ph > 0 do
        local side = minimum(pw, ph) + 0.0
        local row: {integer} = {pending[1]}
        local row_areas: {number} = {area_of(pending[1])}
        local cursor = 2
        while cursor <= #pending do
            local trial: {number} = {}
            for _, a in ipairs(row_areas) do trial[#trial + 1] = a end
            trial[#trial + 1] = area_of(pending[cursor])
            if worst(trial, side) > worst(row_areas, side) then break end
            row[#row + 1] = pending[cursor]
            row_areas[#row_areas + 1] = area_of(pending[cursor])
            cursor = cursor + 1
        end
        local row_sum = 0
        for _, a in ipairs(row_areas) do row_sum = row_sum + a end
        local vertical = pw >= ph
        local thickness = vertical and clamp(round(row_sum / ph), 1, pw) or clamp(round(row_sum / pw), 1, ph)
        local offset = 0
        for position, index in ipairs(row) do
            local share = row_sum > 0 and area_of(index) / row_sum or 0
            local extent = position == #row and ((vertical and ph or pw) - offset) or
                clamp(round(share * (vertical and ph or pw)), 0, (vertical and ph or pw) - offset)
            if extent > 0 then
                if vertical then placed[index] = {x = px, y = py + offset, width = thickness, height = extent}
                else placed[index] = {x = px + offset, y = py, width = extent, height = thickness} end
            end
            offset = offset + extent
        end
        local remaining: {integer} = {}
        for k = #row + 1, #pending do remaining[#remaining + 1] = pending[k] end
        pending = remaining
        if vertical then px = px + thickness; pw = pw - thickness
        else py = py + thickness; ph = ph - thickness end
    end
    local drawn = 0
    for _, index in ipairs(order) do
        local cell = placed[index]
        if cell and cell.width > 0 and cell.height > 0 then
            local item = items[index]
            local tint = appearance.mix(painter.theme.surface, color(painter, item.role, "accent"), 0.35)
            for row = 0, cell.height - 1 do
                frame.clip(painter, cell.x, cell.y + row, string.rep(" ", cell.width), cell.width, painter.theme.text, tint)
            end
            frame.put(painter, cell.x, cell.y, item.label, cell.width, painter.theme.text, tint)
            if cell.height >= 2 then
                local value = item.note or viz.number(item.value, unit)
                local size = tty.text.width(value)
                if size <= cell.width then
                    frame.put(painter, cell.x + cell.width - size, cell.y + cell.height - 1, value, size, painter.theme.text, tint)
                end
            end
            frame.add_hit(painter, "tile", index, item.label, cell.x, cell.y, cell.width, cell.height)
            drawn = drawn + 1
        end
    end
    return drawn
end

-- An icicle (flame) chart of a value tree: root spans rect's full width on
-- its first row, each child's width is its own value's share of its
-- parent's width (an unaccounted remainder stays blank, drawn as self time),
-- one row deeper per level, colored by depth unless role is set, the label
-- baked into the bar when it fits. Nodes past the rect's rows are not drawn.
-- Each drawn node records a "frame" hit of a running index and its label.
-- Returns the number of nodes drawn.
function M.flame(painter: frame.Painter, rect: Rect, root: Frame): integer
    if rect.width <= 0 or rect.height <= 0 then return 0 end
    local theme = painter.theme
    local drawn = 0
    local function place(node: Frame, x: integer, width: integer, depth: integer)
        if width <= 0 or depth >= rect.height or x >= rect.x + rect.width then return end
        width = minimum(width, rect.x + rect.width - x)
        local y = rect.y + depth
        local fg = color(painter, node.role, STACK_ROLES[depth % #STACK_ROLES + 1])
        frame.put(painter, x, y, frame.pad(node.label, width), width, appearance.selection_text(theme), fg)
        drawn = drawn + 1
        frame.add_hit(painter, "frame", drawn, node.label, x, y, width, 1)
        local children = node.children or {}
        if #children == 0 or node.value <= 0 then return end
        local cursor = x
        for _, child in ipairs(children) do
            local child_width = clamp(round(child.value / node.value * width), 0, width - (cursor - x))
            if child_width > 0 then
                place(child, cursor, child_width, depth + 1)
                cursor = cursor + child_width
            end
        end
    end
    place(root, rect.x, rect.width, 0)
    return drawn
end

return M
