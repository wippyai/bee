-- MIT. The Process Manager's hive pane: each node's samples become a bounded
-- history, a node that stops answering shows as away with gaps, and the pane
-- charts every node and lists its latest numbers.
local test = require("test")
local appearance = require("appearance")
local viz = require("viz")
local hive = require("hive")
local view = require("view")

local MIB = 1048576

local function stats(heap: number, goroutines: number, apps: number, name: string): {[string]: unknown}
    return {node = "x", name = name, heap = heap, reserved = heap * 2, goroutines = goroutines, cpu_count = 8,
        apps = apps, workspaces = 1}
end

local function define_tests()
    test.describe("Process Manager hive", function()
        test.it("keeps this node first and records each node's numbers", function()
            local state = hive.new("node-a")
            hive.record(state, {hive.decode("node-b", stats(30 * MIB, 40, 1, "beta"), nil),
                hive.decode("node-a", stats(20 * MIB, 50, 3, "alpha"), nil)})
            local nodes = hive.nodes(state)
            test.eq(#nodes, 2)
            test.eq(nodes[1].node, "node-a")
            test.is_true(nodes[1].here)
            test.eq(nodes[1].name, "alpha")
            test.eq(viz.latest(nodes[2].heap), 30 * MIB)
            test.eq(nodes[1].latest.apps, 3)
        end)

        test.it("shows a node that stops answering as away and leaves gaps, not zeroes", function()
            local state = hive.new("node-a")
            hive.record(state, {hive.decode("node-b", stats(30 * MIB, 40, 1, "beta"), nil)})
            hive.record(state, {hive.decode("node-b", nil, "node.stats: timeout")})
            hive.record(state, {})
            local item = hive.nodes(state)[1]
            test.is_false(item.online)
            test.eq(item.latest.error, "node.stats: timeout")
            test.eq(item.latest.heap, 30 * MIB)
            local values = viz.values(item.heap)
            test.eq(#values, 3)
            test.eq(values[1], 30 * MIB)
            test.is_true(viz.is_gap(values[2]) and viz.is_gap(values[3]))
        end)

        test.it("charts heap and goroutines per node and lists their latest numbers", function()
            local state = hive.new("node-a")
            for step = 1, 5 do
                hive.record(state, {hive.decode("node-a", stats((10 + step) * MIB, 40 + step, 2, "alpha"), nil),
                    hive.decode("node-b", stats((30 - step) * MIB, 60, 1, "beta"), nil)})
            end
            local drawn = view.draw_hive(100, 30, hive.nodes(state), appearance.defaults(), "node-b", 0, false, "")
            local screen = table.concat(drawn.rows, "\n"):gsub("\27%[[0-9;]*m", "")
            for _, wanted in ipairs({"Hive", "HEAP", "GOROUTINES", "NODES", "alpha", "beta", "this node", "online",
                "15.0 MiB", "25.0 MiB", "45", "node-b"}) do
                test.is_true(screen:find(wanted, 1, true) ~= nil, "pane shows " .. wanted)
            end
            local small = view.draw_hive(40, 10, hive.nodes(state), appearance.defaults(), "", 0, true, "")
            test.eq(#small.rows, 10)
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
