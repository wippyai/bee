-- MIT. Compact process views keep their mode and health visible, and native
-- sampler text cannot inject terminal controls.
local test = require("test")
local appearance = require("appearance")
local probe = require("probe")
local tty = require("tty")
local view = require("view")

local function snapshot(): probe.Snapshot
    return {
        processes = {{pid = "pid-12345678", source = "worker\27[2J", host = "main", state = "idle\r", steps = 9}},
        services = {{id = "service\7", state = "running\27[31m", desired = "running", restarts = 0}},
        heap = 1048576, heap_objects = 1, reserved = 2097152, gc_cycles = 1, goroutines = 2,
        queue = 0, executed = 9, host_executed = {main = 9}, error = "native\27[2Jerror",
    }
end

local function define_tests()
    test.describe("Process Manager frame", function()
        test.it("fits every responsive geometry in both modes and strips hostile text", function()
            local sample = snapshot()
            local history = probe.new_history()
            probe.append(history, sample, nil, 0)
            for _, services in ipairs({false, true}) do
                local rows = view.items(sample, services)
                for _, width in ipairs({1, 20, 40, 80, 120}) do
                    for _, height in ipairs({1, 6, 12, 24}) do
                        local frame = view.draw(width, height, sample, history, appearance.defaults(), rows[1].pid,
                            0, false, "", false, services, rows, false)
                        test.eq(#frame.rows, height)
                        for _, row in ipairs(frame.rows) do
                            test.eq(tty.text.width(row), width)
                            local rendered = row:gsub("\27%[[0-9;]*m", "")
                            test.is_nil(rendered:find("\27", 1, true))
                            test.is_nil(rendered:find("\r", 1, true))
                            test.is_nil(rendered:find("\7", 1, true))
                        end
                    end
                end
            end
        end)
        test.it("shows the active compact mode and bounds native text", function()
            local sample = snapshot()
            local history = probe.new_history()
            probe.append(history, sample, nil, 0)
            local process_rows = view.items(sample, false)
            local processes = table.concat(view.draw(24, 10, sample, history, appearance.defaults(), process_rows[1].pid,
                0, false, "", false, false, process_rows, false).rows, "\n")
            test.is_true(processes:find("Processes", 1, true) ~= nil)
            test.is_true(processes:find("idle", 1, true) ~= nil)
            test.is_nil(processes:find("\27[2J", 1, true))
            test.is_nil(processes:find("\r", 1, true))

            sample.error = ""
            local service_rows = view.items(sample, true)
            local services = table.concat(view.draw(24, 10, sample, history, appearance.defaults(), service_rows[1].pid,
                0, false, "", false, true, service_rows, false).rows, "\n")
            test.is_true(services:find("Services", 1, true) ~= nil)
            test.is_true(services:find("running", 1, true) ~= nil)
            test.is_nil(services:find("\27[31m", 1, true))
            test.is_nil(services:find("\7", 1, true))
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
