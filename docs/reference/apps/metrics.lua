-- SPDX-License-Identifier: MIT
-- Reference: live metrics monitor.
-- Demonstrates stat tiles with sparklines over four cards (line chart,
-- capacity rings, traffic mix, latency histogram). Live values live in
-- bounded viz.series rings: the process pushes one sample per redraw tick
-- (gated by viz.due) and the view reads viz.values, so memory stays fixed.
--
-- Library calls: viz.series, viz.push, viz.values, viz.cadence, viz.due,
-- viz.tiles, viz.line, viz.ring, viz.stacked, viz.histogram, frame.stack,
-- frame.cards, frame.card.
local frame = require("frame")
local viz = require("viz")

local M = {}

type Model = {load: viz.Series, memory: viz.Series, latency: viz.Series, requests: viz.Series,
    cadence: viz.Cadence, step: integer, selected: integer}

local GAUGES: {{name: string, value: number}} = {{name = "CPU", value = 68}, {name = "Disk", value = 42}, {name = "GPU", value = 91}}

function M.new(): Model
    return {load = viz.series(48), memory = viz.series(48), latency = viz.series(48), requests = viz.series(48),
        cadence = viz.cadence(1000), step = 0, selected = 1}
end

-- Pushes one sample into every series.
function M.sample(model: Model)
    model.step = model.step + 1
    local step = model.step
    viz.push(model.load, 53 + math.sin(step * 0.41) * 15)
    viz.push(model.memory, 66 + math.sin(step * 0.17) * 4)
    viz.push(model.latency, 86 + math.cos(step * 0.29) * 24)
    viz.push(model.requests, 142 + math.sin(step * 0.36) * 34)
end

-- Handles a ticker event: samples when the cadence says a frame is due and
-- returns whether the screen needs a redraw.
function M.tick(model: Model, now_ms: integer): boolean
    if not viz.due(model.cadence, now_ms) then return false end
    M.sample(model)
    return true
end

function M.draw(painter: frame.Painter, work: frame.Rect, model: Model)
    local requests, latency = viz.values(model.requests), viz.values(model.latency)
    local parts = frame.stack(work, {4, 0}, 1)
    viz.tiles(painter, parts[1], {
        {label = "Requests/s", value = viz.number(viz.latest(model.requests) or 0, ""), note = "live", role = "accent", values = requests},
        {label = "p95", value = viz.number(viz.latest(model.latency) or 0, "ms"), note = "live", role = "warn", values = latency},
        {label = "Errors", value = "0.4%", note = "1h", role = "ok"},
    }, 18)
    frame.cards(painter, parts[2], 4, model.selected, function(cell: frame.Rect, index: integer)
        local titles = {"CPU and memory", "Capacity", "Traffic mix", "Latency histogram"}
        local inner = frame.card(painter, cell, "card", index, titles[index] or "", model.selected == index)
        if index == 1 then
            viz.line(painter, inner, {{values = viz.values(model.load), role = "accent", label = "CPU"},
                {values = viz.values(model.memory), role = "ok", label = "Mem"}}, {min = 0, max = 100, unit = "%"})
        elseif index == 2 then
            for slot, part in ipairs(frame.split(inner, {0, 0, 0}, 1)) do
                local gauge = GAUGES[slot]
                if gauge then viz.ring(painter, part, gauge.value, 100, {label = gauge.name, warn = 75, error = 90}) end
            end
        elseif index == 3 then
            viz.stacked(painter, inner, {{label = "web", segments = {60, 30, 10}}, {label = "api", segments = {40, 40, 20}}},
                {"ok", "slow", "error"}, {percent = true})
        else
            viz.histogram(painter, inner, latency, 8, {min = 40, max = 140, unit = "ms"})
        end
    end)
end

return M
