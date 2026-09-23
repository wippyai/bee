local test = require("test")
local probe = require("probe")
local viz = require("viz")

local function snapshot(executed: number?, hosts: {[string]: number}, heap: number?, queue: number?): probe.Snapshot
    return {
        processes = {},
        services = {},
        heap = heap,
        heap_objects = 8,
        reserved = 256,
        gc_cycles = 2,
        goroutines = 4,
        queue = queue,
        executed = executed,
        host_executed = hosts,
        error = "",
    }
end

local function define_tests()
    test.describe("Process sampler history", function()
        test.it("records the first sample as a rate gap", function()
            local history = probe.new_history()
            probe.append(history, snapshot(10, {main = 10}, 128, 2), nil, 0)

            test.eq(#viz.values(history.heap), 1)
            test.eq(viz.values(history.heap)[1], 128)
            test.eq(viz.values(history.queue)[1], 2)
            test.is_true(viz.is_gap(viz.values(history.rate)[1]))
        end)

        test.it("computes scheduler rate from stable host counters", function()
            local history = probe.new_history()
            local previous = snapshot(10, {main = 10}, 128, 2)
            local current = snapshot(16, {main = 16}, 144, 3)
            probe.append(history, current, previous, 2)

            test.eq(viz.values(history.rate)[1], 3)
            test.eq(viz.values(history.heap)[1], 144)
            test.eq(viz.values(history.queue)[1], 3)
        end)

        test.it("leaves an explicit gap for resets and host changes", function()
            local history = probe.new_history()
            local previous = snapshot(16, {main = 16}, 144, 3)
            probe.append(history, snapshot(2, {main = 2}, 160, 4), previous, 1)
            probe.append(history, snapshot(3, {main = 3, worker = 1}, 176, 5), previous, 1)

            test.is_true(viz.is_gap(viz.values(history.rate)[1]))
            test.is_true(viz.is_gap(viz.values(history.rate)[2]))
        end)

        test.it("keeps missing metrics as gaps instead of zeroes", function()
            local history = probe.new_history()
            probe.append(history, snapshot(nil, {}, nil, nil), nil, 1)

            test.is_true(viz.is_gap(viz.values(history.heap)[1]))
            test.is_true(viz.is_gap(viz.values(history.queue)[1]))
            test.is_true(viz.is_gap(viz.values(history.rate)[1]))
            local unavailable = snapshot(nil, {}, nil, nil)
            probe.append(history, unavailable, unavailable, 1)
            test.is_true(viz.is_gap(viz.values(history.rate)[2]))
            probe.append(history, snapshot(0, {}, 0, 0), snapshot(0, {}, 0, 0), math.huge)
            test.is_true(viz.is_gap(viz.values(history.rate)[3]))
        end)

        test.it("bounds every series to the same sixty samples", function()
            local history = probe.new_history()
            local previous: probe.Snapshot? = nil
            for value = 1, 65 do
                local current = snapshot(value, {main = value}, value, value)
                probe.append(history, current, previous, 1)
                previous = current
            end

            test.eq(#viz.values(history.heap), 60)
            test.eq(#viz.values(history.rate), 60)
            test.eq(#viz.values(history.queue), 60)
            test.eq(viz.values(history.heap)[1], 6)
            test.eq(viz.values(history.rate)[1], 1)
            test.eq(viz.latest(history.queue), 65)
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
