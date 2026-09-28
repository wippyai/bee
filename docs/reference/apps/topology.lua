-- SPDX-License-Identifier: MIT
-- Reference: topology and sizes.
-- Demonstrates a mesh of nodes at chosen positions with braille-routed edges
-- and a treemap of sized items (disk by area), as two selectable cards.
--
-- Library calls: frame.cards, frame.card, diagram.mesh, diagram.treemap.
local frame = require("frame")
local diagram = require("diagram")
local viz = require("viz")

local M = {}

type Model = {selected: integer}

local NODES: {diagram.MeshNode} = {
    {id = "hub", label = "hive", role = "accent", note = "3 bees", x = 0.5, y = 0.15},
    {id = "laptop", label = "laptop", role = "ok", note = "2 workspaces", x = 0.1, y = 0.55},
    {id = "tower", label = "tower", role = "ok", note = "qwen3.8", x = 0.5, y = 0.6},
    {id = "vm", label = "build-vm", role = "warn", note = "degraded", x = 0.88, y = 0.5},
    {id = "docker", label = "docker", role = "muted", note = "idle", x = 0.7, y = 0.9},
}
local EDGES: {diagram.MeshEdge} = {
    {from = "hub", to = "laptop", role = "ok"}, {from = "hub", to = "tower", role = "ok"}, {from = "hub", to = "vm", role = "warn"},
    {from = "tower", to = "docker"}, {from = "vm", to = "docker"},
}
local DISK: {viz.Bar} = {
    {label = "models", value = 412, role = "accent"}, {label = "workspaces", value = 188, role = "ok"},
    {label = "logs", value = 96, role = "warn"}, {label = "cache", value = 71}, {label = "other", value = 19, role = "muted"},
}

function M.sample(): Model return {selected = 1} end

function M.draw(painter: frame.Painter, work: frame.Rect, model: Model)
    frame.cards(painter, work, 2, model.selected, function(cell: frame.Rect, index: integer)
        if index == 1 then
            diagram.mesh(painter, frame.card(painter, cell, "card", index, "Hive topology", model.selected == index), NODES, EDGES)
        else
            diagram.treemap(painter, frame.card(painter, cell, "card", index, "Disk by area · GB", model.selected == index), DISK, "GB")
        end
    end)
end

return M
