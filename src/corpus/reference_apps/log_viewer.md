# Reference application: log viewer with a workspace tree

Demonstrates a virtualized log window with search highlighting beside a flattened, already-filtered tree. The process owns the line list, the selection and the query; on a canvas under 100 columns the tree is dropped.

## Source

```lua
-- SPDX-License-Identifier: MIT
-- Reference: log viewer with a workspace tree.
-- Demonstrates a virtualized log window with search highlighting beside a
-- flattened, already-filtered tree. The process owns the line list, the
-- selection and the query; on a canvas under 100 columns the tree is dropped.
--
-- Library calls: frame.split, frame.panel, frame.tree, frame.log.
local frame = require("frame")

local M = {}

type Model = {lines: {frame.LogLine}, selected: integer, offset: integer, query: string}

local TREE: {frame.TreeRow} = {
    {label = "workspace", depth = 0, expandable = true, expanded = true, key = "workspace"},
    {label = "src", depth = 1, expandable = true, expanded = true, key = "src"},
    {label = "app.lua", depth = 2, key = "app.lua"},
    {label = "view.lua", depth = 2, key = "view.lua", role = "warn"},
    {label = "tests", depth = 1, expandable = true, expanded = false, key = "tests"},
}
local MESSAGES = {"request accepted path=/v1/threads", "cache hit ratio 0.96", "retry scheduled after timeout",
    "error: upstream returned 502", "committed revision 41"}
local ROLES = {"text", "muted", "warn", "error", "ok"}

function M.sample(count: integer): Model
    local lines: {frame.LogLine} = {}
    for index = 1, count do
        local kind = (index * 7) % #MESSAGES + 1
        lines[index] = {text = string.format("09:%02d:%02d  %s", (index // 60) % 60, index % 60, MESSAGES[kind]), role = ROLES[kind]}
    end
    return {lines = lines, selected = 1, offset = 0, query = "error"}
end

function M.draw(painter: frame.Painter, work: frame.Rect, model: Model): frame.Window
    local logs = work
    if painter.width >= 100 then
        local panes = frame.split(work, {30, 0}, 2)
        local inner = frame.panel(painter, panes[1], "Workspace")
        frame.tree(painter, inner.y, inner.y + inner.height - 1, {rows = TREE, selected = 0, offset = 0, area = inner})
        logs = panes[2]
    end
    local inner = frame.panel(painter, logs, string.format("Log · %d lines · search \"%s\"", #model.lines, model.query))
    return frame.log(painter, inner.y, inner.y + inner.height - 1,
        {lines = model.lines, selected = model.selected, offset = model.offset, query = model.query, focused = true, area = inner})
end

return M
```
