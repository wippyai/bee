-- MIT. Open telemetry operations return bounded, numeric, path-free output.
local test = require("test")
local funcs = require("funcs")
local types = require("types")
local bounds = require("bounds")
local function call(id: string, request: {[string]: unknown}): {[string]: unknown}
    local result, err = funcs.call(id, request)
    if err or type(result) ~= "table" then error(id .. ": " .. tostring(err)) end
    return result :: {[string]: unknown}
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
            for name, value in pairs(stats.memory :: {[string]: unknown}) do
                test.is_true(type(value) == "number")
                test.is_true(name == "alloc" or name == "total_alloc" or name == "sys" or name == "heap_alloc" or name == "heap_objects" or name == "num_gc")
            end
        end)
        test.it("lists the public catalog in bounded pages", function()
            local page = call("bee.hive.telemetry:catalog_list", {})
            test.is_nil(page.unavailable)
            local found = false
            for _, summary in ipairs(page.operations :: {{[string]: unknown}}) do
                test.eq(table.concat(keys(summary), ","), "mode,operation_ref,revision,title")
                if summary.operation_ref == "bee.hive.telemetry:stats" then found = true end
            end
            test.is_true(found)
            local rest = call("bee.hive.telemetry:catalog_list", {after_operation_ref = "bee.hive.telemetry:presence"})
            local capabilities = false
            for _, summary in ipairs(rest.operations :: {{[string]: unknown}}) do
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
