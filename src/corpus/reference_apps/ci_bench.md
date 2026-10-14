# Reference application: CI and benchmark board

Demonstrates result history as selectable dashboard cards: candlesticks for latency per commit, a scatter of score against cost, 100% stacked bars of results by suite and a job timeline. On a narrow canvas only the selected card is drawn; every card is a mouse target of hit kind "card". viz.stacked, viz.timeline.

## Source

```lua
-- SPDX-License-Identifier: MIT
-- Reference: CI and benchmark board.
-- Demonstrates result history as selectable dashboard cards: candlesticks for
-- latency per commit, a scatter of score against cost, 100% stacked bars of
-- results by suite and a job timeline. On a narrow canvas only the selected
-- card is drawn; every card is a mouse target of hit kind "card".
--
-- Library calls: frame.cards, frame.card, viz.candles, viz.scatter,
-- viz.stacked, viz.timeline.
local frame = require("frame")
local viz = require("viz")

local M = {}

type Model = {selected: integer}

local BENCH: {viz.Candle} = {
    {label = "a1", low = 61, high = 92, open = 70, close = 64}, {label = "b2", low = 58, high = 88, open = 64, close = 60},
    {label = "c3", low = 55, high = 97, open = 60, close = 83}, {label = "d4", low = 63, high = 90, open = 83, close = 71},
    {label = "e5", low = 52, high = 84, open = 71, close = 58}, {label = "f6", low = 50, high = 79, open = 58, close = 52},
}
local SCORES: {viz.Point} = {
    {x = 0.4, y = 61}, {x = 0.9, y = 68}, {x = 1.5, y = 74, role = "ok"}, {x = 2.6, y = 81, role = "ok"},
    {x = 3.4, y = 82}, {x = 4.2, y = 83, role = "warn"}, {x = 1.2, y = 52, role = "error"}, {x = 3.0, y = 66, role = "error"},
}
local SUITES: {viz.Stack} = {
    {label = "unit", segments = {412, 3, 6}}, {label = "api", segments = {188, 9, 2}},
    {label = "e2e", segments = {64, 11, 5}}, {label = "bench", segments = {30, 1, 0}},
}
local JOBS: {viz.Lane} = {
    {label = "lint", spans = {{start = 0, finish = 12, role = "ok"}}},
    {label = "unit", spans = {{start = 8, finish = 47, role = "ok"}}},
    {label = "e2e", spans = {{start = 47, finish = 91, role = "warn"}}},
    {label = "bench", spans = {{start = 61, finish = 100, role = "accent"}}},
}

function M.sample(): Model return {selected = 1} end

function M.draw(painter: frame.Painter, work: frame.Rect, model: Model)
    frame.cards(painter, work, 4, model.selected, function(cell: frame.Rect, index: integer)
        local titles = {"Bench latency per commit", "Score vs cost", "Results by suite", "Job timeline"}
        local inner = frame.card(painter, cell, "card", index, titles[index] or "", model.selected == index)
        if index == 1 then
            viz.candles(painter, inner, BENCH, {min = 40, max = 100, unit = "ms"})
        elseif index == 2 then
            viz.scatter(painter, inner, SCORES, {x_min = 0, x_max = 5, y_min = 40, y_max = 100, unit = "$"})
        elseif index == 3 then
            viz.stacked(painter, inner, SUITES, {"pass", "fail", "skip"}, {percent = true})
        else
            viz.timeline(painter, inner, JOBS, {from = 0, to = 100, now = 100, from_label = "0m", to_label = "9m"})
        end
    end)
end

return M
```
