-- MIT. Partial runtime observations preserve unavailable measurements, reject
-- malformed source data, and bound snapshots and stop waits.
local test = require("test")
local probe = require("probe")
local stop_request = require("stop_request")

local function define_tests()
    test.describe("Host processes probe", function()
        test.it("keeps partial samples and malformed counters unavailable", function()
            local snapshot = probe.sample_with({
                hosts = function(): (unknown, unknown?)
                    return {{id = "host-a", queue_depth = "bad", executed = 4},
                        {id = "host-b", queue_depth = 3, executed = 4}}, nil
                end,
                processes = function(host_id: string): (unknown, unknown?)
                    if host_id == "host-a" then
                        return {{pid = "{node@host-a|1}", source = "bee.app:run", state = "running", steps = "bad"},
                            {pid = 42, source = "bee.app:run", state = "running", steps = 2}}, nil
                    end
                    return nil, "process source unavailable"
                end,
                services = function(): (unknown, unknown?)
                    return {{id = "bee.app", status = "running", desired = "running", retry_count = -1}}, nil
                end,
                memory = function(): (unknown, unknown?)
                    return {heap_alloc = -1, heap_objects = 3, sys = 4096, num_gc = "bad"}, nil
                end,
                goroutines = function(): (unknown, unknown?) return -1, nil end,
            })
            test.is_nil(snapshot.queue)
            test.eq(snapshot.executed, 8)
            test.is_nil(snapshot.heap)
            test.eq(snapshot.heap_objects, 3)
            test.is_nil(snapshot.gc_cycles)
            test.is_nil(snapshot.goroutines)
            test.eq(#snapshot.processes, 1)
            test.is_nil(snapshot.processes[1].steps)
            test.eq(#snapshot.services, 1)
            test.is_nil(snapshot.services[1].restarts)
            test.is_true(snapshot.error:find("queue counter unavailable", 1, true) ~= nil)
            test.is_true(snapshot.error:find("process source unavailable", 1, true) ~= nil)
        end)

        test.it("rejects oversized host, process and service snapshots", function()
            local hosts: {{[string]: unknown}} = {}
            for index = 1, probe.MAX_HOSTS + 1 do
                hosts[index] = {id = "host-" .. tostring(index), queue_depth = 0, executed = 0}
            end
            local enumerated = 0
            local oversized_hosts = probe.sample_with({
                hosts = function(): (unknown, unknown?) return hosts, nil end,
                processes = function(_host_id: string): (unknown, unknown?) enumerated = enumerated + 1; return {}, nil end,
                services = function(): (unknown, unknown?) return {}, nil end,
                memory = function(): (unknown, unknown?) return {heap_alloc = 0, heap_objects = 0, sys = 0, num_gc = 0}, nil end,
                goroutines = function(): (unknown, unknown?) return 0, nil end,
            })
            test.is_nil(oversized_hosts.queue)
            test.eq(enumerated, 0)
            test.is_true(oversized_hosts.error:find("oversized host snapshot", 1, true) ~= nil)

            local one_host: {unknown} = {{id = "host-a", queue_depth = 0, executed = 0}}
            local processes: {{[string]: unknown}} = {}
            for index = 1, probe.MAX_PROCESSES + 1 do
                processes[index] = {pid = "p" .. tostring(index), source = "bee.app:run", state = "running", steps = 0}
            end
            local oversized_processes = probe.sample_with({
                hosts = function(): (unknown, unknown?) return one_host, nil end,
                processes = function(_host_id: string): (unknown, unknown?) return processes, nil end,
                services = function(): (unknown, unknown?) return {}, nil end,
                memory = function(): (unknown, unknown?) return {heap_alloc = 0, heap_objects = 0, sys = 0, num_gc = 0}, nil end,
                goroutines = function(): (unknown, unknown?) return 0, nil end,
            })
            test.eq(#oversized_processes.processes, 0)
            test.is_true(oversized_processes.error:find("oversized process snapshot", 1, true) ~= nil)

            local services: {{[string]: unknown}} = {}
            for index = 1, probe.MAX_SERVICES + 1 do
                services[index] = {id = "service-" .. tostring(index), status = "running", desired = "running", retry_count = 0}
            end
            local oversized_services = probe.sample_with({
                hosts = function(): (unknown, unknown?) return {}, nil end,
                processes = function(_host_id: string): (unknown, unknown?) return {}, nil end,
                services = function(): (unknown, unknown?) return services, nil end,
                memory = function(): (unknown, unknown?) return {heap_alloc = 0, heap_objects = 0, sys = 0, num_gc = 0}, nil end,
                goroutines = function(): (unknown, unknown?) return 0, nil end,
            })
            test.eq(#oversized_services.services, 0)
            test.is_true(oversized_services.error:find("oversized service snapshot", 1, true) ~= nil)
        end)

        test.it("keeps the exact stop request pending until a correlated reply", function()
            local pending = stop_request.begin("request-1")
            test.is_true(stop_request.matches(pending, "request-1"))
            test.is_false(stop_request.matches(pending, "request-2"))
            test.is_false(stop_request.matches(pending, nil))
            test.is_true(stop_request.matches(pending, "request-1"))
        end)
    end)
end

return test.run_cases(define_tests)
