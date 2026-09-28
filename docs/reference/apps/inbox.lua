-- SPDX-License-Identifier: MIT
-- Reference: inbox and approvals.
-- Demonstrates who asked, from which bee, for what and by when: a table of
-- requests with a key-value detail pane for the selected one. The model
-- function decide commits a verdict and returns the text for a toast, so the
-- application shows the outcome with the overlays reference.
--
-- Library calls: frame.master_detail, frame.table, frame.panel, frame.kv.
local frame = require("frame")

local M = {}

type Request = {from: string, bee: string, request: string, due: string, detail: {frame.Entry}}
type Model = {requests: {Request}, selected: integer, offset: integer}

function M.sample(): Model
    return {selected = 1, offset = 0, requests = {
        {from = "maria", bee = "reviewer", request = "Merge release/2.14 into main", due = "today",
            detail = {{label = "Branch", value = "release/2.14"}, {label = "Checks", value = "212 passed, 0 failed"},
                {label = "Diff", value = "+1,204 -388 in 41 files"}, {label = "Risk", value = "medium", role = "warn"}}},
        {from = "ops-bee", bee = "deployer", request = "Deploy edge-api v2.14.1 to prod", due = "1h",
            detail = {{label = "Service", value = "edge-api"}, {label = "Target", value = "prod / eu-west"},
                {label = "Rollback", value = "automatic", role = "ok"}}},
        {from = "cost-bee", bee = "planner", request = "Raise model budget to $40/day", due = "3d",
            detail = {{label = "Current", value = "$25/day"}, {label = "Requested", value = "$40/day"}}},
    }}
end

-- Removes the selected request, keeps the selection in range and returns the toast text.
function M.decide(model: Model, approve: boolean): string?
    local request = model.requests[model.selected]
    if not request then return nil end
    table.remove(model.requests, model.selected)
    model.selected = math.max(1, math.min(#model.requests, model.selected))
    return (approve and "Approved: " or "Denied: ") .. request.request
end

function M.draw(painter: frame.Painter, work: frame.Rect, model: Model): frame.Window
    local list, detail = frame.master_detail(painter, work)
    local parts = frame.stack(list, {1, 0}, 0)
    frame.put(painter, list.x + 1, list.y, string.format("INBOX · %d waiting", #model.requests), list.width - 1, painter.theme.muted)
    local first, last = parts[2].y, parts[2].y + parts[2].height - 1
    local cells: {{string}} = {}
    local keys: {string} = {}
    for index, item in ipairs(model.requests) do
        cells[index] = {item.from, item.bee, item.request, item.due}
        keys[index] = item.request
    end
    local window = frame.window(#model.requests, last - first, model.selected, model.offset)
    frame.table(painter, first, last, {
        columns = {{title = "From", width = 9}, {title = "Bee", width = 10}, {title = "Request", width = 0}, {title = "Due", width = 9}},
        cells = cells, keys = keys, kind = "request", selected = model.selected, offset = window.offset,
        area = parts[2],
    })
    local item = model.requests[model.selected]
    if not detail or not item then return window end
    local inner = frame.panel(painter, detail, "Request details")
    if inner.height < 3 then return window end
    frame.put(painter, inner.x, inner.y, item.request, inner.width, painter.theme.text)
    frame.kv(painter, inner.y + 2, inner.y + inner.height - 1, {entries = item.detail, selected = 0, offset = 0})
    return window
end

return M
