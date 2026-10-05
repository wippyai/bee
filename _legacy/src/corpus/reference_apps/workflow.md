# Reference application: durable workflow

Demonstrates a layered step graph with per-step notes and a flame chart of step durations, as two selectable cards. A spinner in the title shows work in flight; the application advances the tick.

## Source

```lua
-- SPDX-License-Identifier: MIT
-- Reference: durable workflow.
-- Demonstrates a layered step graph with per-step notes and a flame chart of
-- step durations, as two selectable cards. A spinner in the title shows work
-- in flight; the application advances the tick.
--
-- Library calls: frame.cards, frame.card, viz.graph, viz.spinner, diagram.flame.
local frame = require("frame")
local diagram = require("diagram")
local viz = require("viz")

local M = {}

type Model = {selected: integer, tick: integer}

local NODES: {viz.Node} = {
    {id = "plan", label = "Plan", role = "ok", note = "12s"},
    {id = "fetch", label = "Fetch", role = "ok", note = "41s"},
    {id = "build", label = "Build", role = "ok", note = "3m"},
    {id = "review", label = "Review", role = "warn", note = "waiting"},
    {id = "ship", label = "Ship", role = "muted", note = "queued"},
}
local EDGES: {viz.Edge} = {{from = "plan", to = "fetch"}, {from = "plan", to = "build"}, {from = "fetch", to = "review"},
    {from = "build", to = "review"}, {from = "review", to = "ship"}}
local FLAME: diagram.Frame = {label = "workflow", value = 100, children = {
    {label = "plan", value = 8},
    {label = "fetch", value = 22, children = {{label = "clone", value = 14}, {label = "index", value = 6}}},
    {label = "build", value = 46, children = {{label = "compile", value = 28, children = {{label = "link", value = 9}}}, {label = "test", value = 14}}},
    {label = "review", value = 14},
}}

function M.sample(): Model return {selected = 1, tick = 0} end

function M.draw(painter: frame.Painter, work: frame.Rect, model: Model)
    frame.cards(painter, work, 2, model.selected, function(cell: frame.Rect, index: integer)
        if index == 1 then
            local inner = frame.card(painter, cell, "card", index, "Durable workflow " .. viz.spinner(model.tick), model.selected == index)
            viz.graph(painter, inner, NODES, EDGES)
        else
            diagram.flame(painter, frame.card(painter, cell, "card", index, "Step durations", model.selected == index), FLAME)
        end
    end)
end

return M
```
