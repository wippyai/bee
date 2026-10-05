-- MIT. The diagram kit lays out a mesh, a treemap and an icicle chart inside
-- the rectangle it is given, colors marks from semantic roles and keeps no
-- state between frames, at every size and without leaking escape codes.
local test = require("test")
local tty = require("tty")
local frame = require("frame")
local viz = require("viz")
local diagram = require("diagram")
local appearance = require("appearance")

local function plain(row: string): string
    return row:gsub("\27%[[0-9;]*m", "")
end
local function text(painter: frame.Painter): {string}
    local rows: {string} = {}
    for index, row in ipairs(frame.rows(painter)) do rows[index] = plain(row) end
    return rows
end
local function golden(painter: frame.Painter, expected: {string})
    local rows = text(painter)
    test.eq(#rows, #expected)
    for index, row in ipairs(expected) do test.eq(rows[index], row) end
end

local MESH: {string} = {
    "                                        ",
    "                                        ",
    "     ● a⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⣤● b    ",
    "      ⠈⠢⢄                    ⢀⠤⠊        ",
    "         ⠉⠢⣀              ⢀⡠⠊⠁          ",
    "            ⠑⠢⡀         ⡠⠒⠁             ",
    "              ⠈⠑⠤⡀   ⡠⠔⠉                ",
    "                 ⠈⠒● c                  ",
    "                                        ",
    "                                        "}
local TREEMAP: {string} = {
    "                            ",
    " logs        db     cache   ",
    "                            ",
    "                            ",
    "                            ",
    "                            ",
    "           50     30   20   ",
    "                            ",
    "                            "}
local FLAME: {string} = {
    "                                        ",
    " root                                   ",
    " fetch         parse                    ",
    " dns                                    ",
    "                                        ",
    "                                        "}

type Draw = (painter: frame.Painter, rect: frame.Rect) -> ()
local function drawings(): {Draw}
    local nodes: {diagram.MeshNode} = {{id = "a", label = "a", x = 0.1, y = 0.1}, {id = "b", label = "b", x = 0.9, y = 0.1, note = "leaf"},
        {id = "c", label = "c", x = 0.5, y = 0.9}}
    local edges: {diagram.MeshEdge} = {{from = "a", to = "b"}, {from = "b", to = "c"}, {from = "c", to = "a"}}
    local items: {viz.Bar} = {{label = "logs", value = 50}, {label = "db", value = 30}, {label = "cache", value = 20}}
    local tree: diagram.Frame = {label = "root", value = 100, children = {
        {label = "fetch", value = 40, children = {{label = "dns", value = 10}}}, {label = "parse", value = 30}}}
    return {
        function(p: frame.Painter, r: frame.Rect) diagram.mesh(p, r, nodes, edges) end,
        function(p: frame.Painter, r: frame.Rect) diagram.treemap(p, r, items) end,
        function(p: frame.Painter, r: frame.Rect) diagram.flame(p, r, tree) end,
    }
end

local function define_tests()
    test.describe("Diagram kit", function()
        test.it("routes braille edges between placed or ringed nodes without crossing a node's own cell", function()
            local mesh = frame.new(40, 10, appearance.defaults())
            test.eq(diagram.mesh(mesh, {x = 2, y = 2, width = 36, height = 8},
                {{id = "a", label = "a", x = 0.1, y = 0.1}, {id = "b", label = "b", x = 0.9, y = 0.1}, {id = "c", label = "c", x = 0.5, y = 0.9}},
                {{from = "a", to = "b"}, {from = "b", to = "c"}, {from = "c", to = "a"}}), 3)
            golden(mesh, MESH)

            local hit = frame.hit(mesh.hits, 34, 3)
            test.eq(hit and (hit.kind .. ":" .. hit.key) or "", "node:b")

            local ring = frame.new(20, 6, appearance.defaults())
            test.eq(diagram.mesh(ring, {x = 2, y = 2, width = 16, height = 4},
                {{id = "1", label = "1"}, {id = "2", label = "2"}, {id = "3", label = "3"}, {id = "4", label = "4"}}, {}), 4)
        end)
        test.it("keeps automatically placed mesh nodes inside a tiny rectangle", function()
            local nodes = {{id = "1", label = "one"}, {id = "2", label = "two"}, {id = "3", label = "three"}}
            for _, size in ipairs({{1, 1}, {2, 1}, {1, 3}, {2, 2}, {3, 2}}) do
                local painter = frame.new(12, 8, appearance.defaults())
                local rect = {x = 5, y = 4, width = size[1], height = size[2]}
                diagram.mesh(painter, rect, nodes, {{from = "1", to = "2"}})
                for _, hit in ipairs(painter.hits) do
                    test.is_true(hit.x >= rect.x and hit.x <= rect.x + rect.width - 1)
                    test.is_true(hit.y >= rect.y and hit.y <= rect.y + rect.height - 1)
                end
                for row, line in ipairs(text(painter)) do
                    for column = 1, 12 do
                        local inside = column >= rect.x and column < rect.x + rect.width and row >= rect.y and row < rect.y + rect.height
                        if not inside then test.eq(tty.text.cut(line, column - 1, column), " ") end
                    end
                end
            end
        end)
        test.it("squarifies a treemap to positive values only and marks tile hits", function()
            local treemap = frame.new(28, 9, appearance.defaults())
            test.eq(diagram.treemap(treemap, {x = 2, y = 2, width = 24, height = 6},
                {{label = "logs", value = 50}, {label = "db", value = 30}, {label = "cache", value = 20}}), 3)
            golden(treemap, TREEMAP)
            local hit = frame.hit(treemap.hits, 3, 2)
            test.eq(hit and (hit.kind .. ":" .. hit.index) or "", "tile:1")

            local skipped = frame.new(20, 6, appearance.defaults())
            test.eq(diagram.treemap(skipped, {x = 2, y = 2, width = 16, height = 4},
                {{label = "zero", value = 0}, {label = "negative", value = -1}, {label = "kept", value = 5}}), 1)
        end)
        test.it("lays out an icicle chart with children sharing their parent's width", function()
            local flame = frame.new(40, 6, appearance.defaults())
            test.eq(diagram.flame(flame, {x = 2, y = 2, width = 36, height = 4}, {label = "root", value = 100, children = {
                {label = "fetch", value = 40, children = {{label = "dns", value = 10}}}, {label = "parse", value = 30}}}), 4)
            golden(flame, FLAME)
            local hit = frame.hit(flame.hits, 3, 3)
            test.eq(hit and (hit.kind .. ":" .. hit.key) or "", "frame:fetch")
        end)
        test.it("draws only inside its rectangle at every size and keeps rows at the canvas width", function()
            for number, draw in ipairs(drawings()) do
                for _, size in ipairs({{0, 0}, {1, 1}, {3, 2}, {8, 3}, {20, 4}, {38, 9}, {78, 19}}) do
                    local painter = frame.new(size[1] + 4, size[2] + 4, appearance.defaults())
                    local rect: frame.Rect = {x = 3, y = 3, width = size[1], height = size[2]}
                    draw(painter, rect)
                    local rows = text(painter)
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
