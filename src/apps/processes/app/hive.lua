-- MIT. The Process Manager's hive view: each node's runtime numbers, sampled
-- from its owner while the view is open, with a bounded history per node.
-- A node that does not answer keeps its last numbers and shows as away; its
-- series take a gap, never a zero.
local viz = require("viz")
local bounds = require("bounds")

local M = {}
M.HISTORY_LIMIT = 60

type Sample = {node: string, name: string, heap: number?, reserved: number?, goroutines: number?, cpu_count: number?,
    apps: number?, workspaces: number?, error: string?}
type Node = {node: string, name: string, here: boolean, online: boolean, latest: Sample,
    heap: viz.Series, goroutines: viz.Series, apps: viz.Series}
type Hive = {nodes: {[string]: Node}, here: string}

function M.new(here: string): Hive
    return {nodes = {}, here = here}
end

local function number(value: unknown): number?
    local counted = bounds.count(value)
    if counted == nil then return nil end
    return counted
end

-- decode reads one node's stats reply; a refused or malformed reply is the
-- node's error.
function M.decode(node: string, value: unknown, problem: string?): Sample
    local object = bounds.object(value)
    if problem or not object then
        return {node = node, name = node, error = problem or "malformed stats"}
    end
    local name = bounds.line(object.name, 80)
    return {node = node, name = name and name ~= "" and name or node, heap = number(object.heap),
        reserved = number(object.reserved), goroutines = number(object.goroutines), cpu_count = number(object.cpu_count),
        apps = number(object.apps), workspaces = number(object.workspaces), error = nil}
end

-- record adds one sampling round; nodes absent from it are away.
function M.record(hive: Hive, samples: {Sample})
    local seen: {[string]: boolean} = {}
    for _, sample in ipairs(samples) do
        seen[sample.node] = true
        local item = hive.nodes[sample.node]
        if not item then
            item = {node = sample.node, name = sample.name, here = sample.node == hive.here, online = false, latest = sample,
                heap = viz.series(M.HISTORY_LIMIT), goroutines = viz.series(M.HISTORY_LIMIT), apps = viz.series(M.HISTORY_LIMIT)}
            hive.nodes[sample.node] = item
        end
        if sample.error then
            item.online = false
            item.latest.error = sample.error
            viz.push(item.heap, viz.GAP); viz.push(item.goroutines, viz.GAP); viz.push(item.apps, viz.GAP)
        else
            item.online, item.name, item.latest = true, sample.name, sample
            viz.push(item.heap, sample.heap or viz.GAP)
            viz.push(item.goroutines, sample.goroutines or viz.GAP)
            viz.push(item.apps, sample.apps or viz.GAP)
        end
    end
    for id, item in pairs(hive.nodes) do
        if not seen[id] then
            item.online = false
            viz.push(item.heap, viz.GAP); viz.push(item.goroutines, viz.GAP); viz.push(item.apps, viz.GAP)
        end
    end
end

-- nodes lists the hive's nodes: this node first, then by name.
function M.nodes(hive: Hive): {Node}
    local listed: {Node} = {}
    for _, item in pairs(hive.nodes) do listed[#listed + 1] = item end
    table.sort(listed, function(a: Node, b: Node): boolean
        if a.here ~= b.here then return a.here end
        if a.name ~= b.name then return a.name < b.name end
        return a.node < b.node
    end)
    return listed
end

return M
