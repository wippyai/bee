# Reference application: deploy board

Demonstrates a headline row of stat tiles over a run table with a detail pane. The detail pane shows a state badge, a spinner for work in flight, progress with an ETA and the pipeline stage graph. The view is pure: the application owns the selection, the table offset and the animation tick, and stores the returned window's offset for the next frame. frame.badge, viz.tiles, viz.progress, viz.graph, viz.spinner.

## Source

```lua
-- SPDX-License-Identifier: MIT
-- Reference: deploy board.
-- Demonstrates a headline row of stat tiles over a run table with a detail
-- pane. The detail pane shows a state badge, a spinner for work in flight,
-- progress with an ETA and the pipeline stage graph. The view is pure: the
-- application owns the selection, the table offset and the animation tick,
-- and stores the returned window's offset for the next frame.
--
-- Library calls: frame.stack, frame.master_detail, frame.table, frame.panel,
-- frame.badge, viz.tiles, viz.progress, viz.graph, viz.spinner.
local frame = require("frame")
local viz = require("viz")

local M = {}

type Run = {service: string, env: string, version: string, state: string, age: string, done: number, total: number, eta: string}
type Model = {runs: {Run}, selected: integer, offset: integer, tick: integer}

local STAGES: {viz.Node} = {
    {id = "build", label = "Build", role = "ok", note = "1m 12s"},
    {id = "test", label = "Test", role = "ok", note = "4m 03s"},
    {id = "stage", label = "Stage", role = "warn", note = "running"},
    {id = "canary", label = "Canary", role = "muted", note = "waiting"},
    {id = "prod", label = "Prod", role = "muted", note = "waiting"},
}
local EDGES: {viz.Edge} = {{from = "build", to = "test"}, {from = "test", to = "stage"},
    {from = "stage", to = "canary"}, {from = "canary", to = "prod"}}

-- The color role of a run state.
local function role_of(state: string): string
    if state == "failed" then return "error" end
    if state == "running" or state == "canary" then return "warn" end
    if state == "queued" then return "muted" end
    return "ok"
end

function M.sample(): Model
    return {selected = 1, offset = 0, tick = 0, runs = {
        {service = "edge-api", env = "prod", version = "v2.14.1", state = "running", age = "2m", done = 3180, total = 4000, eta = "40s"},
        {service = "billing-sync", env = "prod", version = "v1.9.0", state = "canary", age = "9m", done = 12, total = 20, eta = "3m"},
        {service = "search-index", env = "stage", version = "v3.2.0", state = "succeeded", age = "21m", done = 8, total = 8, eta = "0s"},
        {service = "image-proxy", env = "prod", version = "v0.8.7", state = "failed", age = "33m", done = 5, total = 8, eta = "-"},
        {service = "event-router", env = "prod", version = "v4.0.0", state = "queued", age = "1h", done = 0, total = 8, eta = "12m"},
    }}
end

-- Draws the board into work and returns the table window.
function M.draw(painter: frame.Painter, work: frame.Rect, model: Model): frame.Window
    local parts = frame.stack(work, {4, 0}, 1)
    viz.tiles(painter, parts[1], {
        {label = "Deploys today", value = "27", note = "+4 vs avg", role = "ok"},
        {label = "Success rate", value = "96%", note = "7 days", role = "ok"},
        {label = "Median time", value = "6m 40s", note = "p50", role = "accent"},
        {label = "In flight", value = "2", note = "1 canary", role = "warn"},
    }, 18)
    local list, detail = frame.master_detail(painter, parts[2])
    local cells: {{string}} = {}
    local keys: {string} = {}
    for index, run in ipairs(model.runs) do
        cells[index] = {run.service, run.env, run.version, run.state, run.age}
        keys[index] = run.service
    end
    local window = frame.window(#model.runs, list.height - 1, model.selected, model.offset)
    frame.table(painter, list.y, list.y + list.height - 1, {
        columns = {{title = "Service", width = 0}, {title = "Env", width = 6}, {title = "Version", width = 9},
            {title = "State", width = 10}, {title = "Age", width = 5, align = "right"}},
        cells = cells, keys = keys, kind = "run", selected = model.selected, offset = window.offset, area = list,
    })
    local run = model.runs[model.selected]
    if not detail or not run then return window end
    local inner = frame.panel(painter, detail, run.service .. " · " .. run.version)
    if inner.height <= 0 then return window end
    frame.badge(painter, inner.x, inner.y, run.state, role_of(run.state))
    if role_of(run.state) == "warn" then
        frame.put(painter, inner.x + #run.state + 3, inner.y, viz.spinner(model.tick), 2, painter.theme.warn)
    end
    local rows = frame.stack(inner, {1, 1, 0}, 1)
    viz.progress(painter, rows[2].x, rows[2].y, rows[2].width, run.done, run.total,
        {label = "Steps", eta = run.eta ~= "-" and run.eta or nil})
    if rows[3].height > 1 then
        frame.put(painter, rows[3].x, rows[3].y, "PIPELINE", rows[3].width, painter.theme.muted)
        viz.graph(painter, {x = rows[3].x, y = rows[3].y + 1, width = rows[3].width, height = rows[3].height - 1}, STAGES, EDGES)
    end
    return window
end

return M
```
