-- MIT. Open telemetry operations return bounded, numeric, path-free output.
local test = require("test")
local funcs = require("funcs")
local types = require("types")
local bounds = require("bounds")
local sampling = require("sampling")
local function call(id: string, request: {[string]: unknown}): {[string]: unknown}
    local result, err = funcs.call(id, request)
    if err or type(result) ~= "table" then error(id .. ": " .. tostring(err)) end
    local value = bounds.object(result)
    if not value then error("telemetry result must be an object") end
    return value
end
local function keys(value: {[string]: unknown}): {string}
    local list: {string} = {}
    for key in pairs(value) do list[#list + 1] = key end
    table.sort(list)
    return list
end
local function define_tests()
    test.describe("Hive telemetry", function()
        test.it("reports presence with only the declared fields", function()
            local presence = call("bee.hive.telemetry:presence", {})
            test.eq(table.concat(keys(presence), ","), "cluster_size,node_id,protocol_revision,role,sampled_at")
            test.eq(presence.protocol_revision, types.REVISION)
            test.is_true(type(presence.cluster_size) == "number")
            test.not_nil(bounds.timestamp(presence.sampled_at))
        end)
        test.it("reports numeric statistics only", function()
            local stats = call("bee.hive.telemetry:stats", {})
            test.eq(table.concat(keys(stats), ","), "cpu_count,goroutines,memory,sampled_at")
            test.is_true(type(stats.goroutines) == "number" and stats.goroutines > 0)
            for name, value in pairs(assert(bounds.object(stats.memory))) do
                test.is_true(type(value) == "number")
                test.is_true(name == "alloc" or name == "total_alloc" or name == "sys" or name == "heap_alloc" or name == "heap_objects" or name == "num_gc")
            end
        end)
        test.it("refuses unavailable or malformed runtime samples instead of fabricating measurements", function()
            local valid_time = function(): string return "2026-09-26T12:00:00.000Z" end
            local missing = function(): (unknown, unknown?) return nil, "source unavailable" end
            local presence, presence_error = sampling.presence({
                node_id = missing,
                role = function(): (unknown, unknown?) return "leader", nil end,
                cluster_size = function(): (unknown, unknown?) return 3, nil end,
                sampled_at = valid_time,
            }, types.REVISION)
            test.is_nil(presence)
            test.not_nil(presence_error)

            local invalid_role, role_error = sampling.presence({
                node_id = function(): (unknown, unknown?) return "node-a", nil end,
                role = function(): (unknown, unknown?) return "", nil end,
                cluster_size = function(): (unknown, unknown?) return 3, nil end,
                sampled_at = valid_time,
            }, types.REVISION)
            test.is_nil(invalid_role)
            test.not_nil(role_error)

            local stats, stats_error = sampling.stats({
                memory = missing,
                goroutines = function(): (unknown, unknown?) return 4, nil end,
                cpu_count = function(): (unknown, unknown?) return 8, nil end,
                sampled_at = valid_time,
            })
            test.is_nil(stats)
            test.not_nil(stats_error)

            local invalid_counters, counter_error = sampling.stats({
                memory = function(): (unknown, unknown?) return {heap_alloc = 1024}, nil end,
                goroutines = function(): (unknown, unknown?) return 1.5, nil end,
                cpu_count = function(): (unknown, unknown?) return 8, nil end,
                sampled_at = valid_time,
            })
            test.is_nil(invalid_counters)
            test.not_nil(counter_error)
        end)
        test.it("lists the public catalog in bounded pages", function()
            local page = call("bee.hive.telemetry:catalog_list", {})
            test.is_nil(page.unavailable)
            local found = false
            for _, raw in ipairs(assert(bounds.array(page.operations))) do
                local summary = assert(bounds.object(raw))
                test.eq(table.concat(keys(summary), ","), "mode,operation_ref,revision,title")
                if summary.operation_ref == "bee.hive.telemetry:stats" then found = true end
            end
            test.is_true(found)
            local rest = call("bee.hive.telemetry:catalog_list", {after_operation_ref = "bee.hive.telemetry:presence"})
            local capabilities = false
            for _, raw in ipairs(assert(bounds.array(rest.operations))) do
                local summary = assert(bounds.object(raw))
                test.is_true(tostring(summary.operation_ref) > "bee.hive.telemetry:presence")
                if summary.operation_ref == "bee.threads:capabilities" then
                    capabilities = true
                    test.eq(summary.mode, "open")
                end
            end
            test.is_true(capabilities)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
