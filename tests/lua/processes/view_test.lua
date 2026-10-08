local history_values = require("history_values")
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
        test.it("lists Bee services by title, folds the runtime into one row, and shows a finished service as done", function()
            local listed: probe.Snapshot = {processes = {}, heap = 1048576, heap_objects = 1, reserved = 2097152, gc_cycles = 1, goroutines = 2, error = "",
                queue = 0, executed = 0, host_executed = {},
                services = {
                    {id = "bee.threads.service:service", title = "Threads · owner", state = "running", desired = "running", restarts = 0},
                    {id = "bee.approvals.service:worker_service", title = "Approvals · delivery", state = "running", desired = "running", restarts = 1},
                    {id = "bee.gov.service:recovery_service", title = "Library · boot recovery", state = "exited", desired = "running", restarts = 0},
                    {id = "bee.sync.service:service", state = "exited", desired = "running", restarts = 3, detail = "sync store unavailable"},
                    {id = "bee:db", state = "running", desired = "running", restarts = 0},
                    {id = "wippy.terminal:host", state = "running", desired = "running", restarts = 0},
                    {id = "wippy.bootloader:bootloader.service", state = "exited", desired = "running", restarts = 0},
                }}
            local rows = view.items(listed, true)
            local labels: {string} = {}
            for _, row in ipairs(rows) do labels[#labels + 1] = row.source .. "=" .. row.state end
            test.eq(table.concat(labels, "|"), "Approvals · delivery=running|bee.sync.service:service=exited|Library · boot recovery=done|Threads · owner=running|Runtime=2 running · 1 done")
            test.eq(rows[#rows].steps, 0)
        end)
        test.it("fits every responsive geometry in both modes and strips hostile text", function()
            local sample = snapshot()
            local history = history_values.new_history()
            history_values.append(history, sample, nil, 0)
            for _, services in ipairs({false, true}) do
                local rows = view.items(sample, services)
                for _, width in ipairs({1, 20, 40, 80, 120}) do
                    for _, height in ipairs({1, 6, 12, 24, 36}) do
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
            local history = history_values.new_history()
            history_values.append(history, sample, nil, 0)
            local process_rows = view.items(sample, false)
            local processes = table.concat(view.draw(24, 10, sample, history, appearance.defaults(), process_rows[1].pid,
                0, false, "", false, false, process_rows, false).rows, "\n")
            test.is_true(processes:find("Processes", 1, true) ~= nil)
            test.is_true(processes:find("idle", 1, true) ~= nil)
            test.is_nil((processes:find("\27[2J", 1, true)))
            test.is_nil((processes:find("\r", 1, true)))

            sample.error = ""
            local service_rows = view.items(sample, true)
            local services = table.concat(view.draw(24, 10, sample, history, appearance.defaults(), service_rows[1].pid,
                0, false, "", false, true, service_rows, false).rows, "\n")
            test.is_true(services:find("Services", 1, true) ~= nil)
            test.is_true(services:find("running", 1, true) ~= nil)
            test.is_nil((services:find("\27[31m", 1, true)))
            test.is_nil((services:find("\7", 1, true)))
        end)
        test.it("names the app, its live state and keys, and tells same-source processes apart by PID suffix", function()
            local sample: probe.Snapshot = {
                processes = {
                    {pid = "{node@bee:workers|0x00017}", source = "bee.apps.settings:app", host = "main", state = "idle", steps = 12},
                    {pid = "{node@bee:workers|0x00018}", source = "bee.apps.settings:app", host = "main", state = "idle", steps = 14},
                    {pid = "{node@bee:workers|0x00002}", source = "bee.host:main", host = "main", state = "idle", steps = 96}},
                services = {}, heap = 1048576, heap_objects = 1, reserved = 2097152, gc_cycles = 1, goroutines = 2,
                queue = 0, executed = 9, host_executed = {main = 9}, error = "",
            }
            local history = history_values.new_history()
            history_values.append(history, sample, nil, 0)
            local rows = view.items(sample, false)
            local drawn = view.draw(80, 24, sample, history, appearance.defaults(), rows[2].pid, 0, false, "", false, false, rows, false)
            local plain: {string} = {}
            for index, row in ipairs(drawn.rows) do plain[index] = row:gsub("\27%[[0-9;]*m", "") end
            local text = table.concat(plain, "\n")
            test.is_true(plain[1]:find("PROCESS MANAGER", 1, true) ~= nil)
            test.is_true(plain[1]:find("Live · 1s · 3 processes", 1, true) ~= nil)
            test.is_true(text:find("bee.apps.settings:app · 0x00017 ", 1, true) ~= nil)
            test.is_true(text:find("bee.apps.settings:app · 0x00018 ", 1, true) ~= nil)
            test.is_nil(text:find("0x00017}", 1, true) and text:find("· 0x00017}", 1, true))

            test.is_true(plain[24]:find("Tab switch · Esc close", 1, true) ~= nil)
            test.is_nil((plain[24]:find("P pause", 1, true)))
            test.is_true(plain[24]:find("Pause", 1, true) ~= nil and plain[24]:find("Stop app", 1, true) ~= nil)
            local kinds: {[string]: boolean} = {}
            for _, hit in ipairs(drawn.hits) do kinds[hit.kind] = true end
            for _, hit in ipairs(drawn.hits) do
                if hit.kind == "pause" or hit.kind == "sort" or hit.kind == "stop" or hit.kind == "frame_help" then test.eq(hit.y, 24) end
            end
            test.is_true(kinds["processes"] and kinds["services"] and kinds["pause"] and kinds["sort"] and kinds["stop"] and kinds["row"])
            local marked = 0
            for _, row in ipairs(plain) do if row:sub(1, #"›") == "›" then marked = marked + 1; test.is_true(row:find("0x00018", 1, true) ~= nil) end end
            test.eq(marked, 1)
            local confirming = view.draw(120, 24, sample, history, appearance.defaults(), rows[2].pid, 0, false, "", true, false, rows, false)
            test.is_true(confirming.rows[23]:find("Stop selected app?", 1, true) ~= nil)
            test.is_true(confirming.rows[24]:find("Enter confirms · Esc cancels", 1, true) ~= nil)
            test.is_true(confirming.rows[24]:find("? help", 1, true) ~= nil)
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
