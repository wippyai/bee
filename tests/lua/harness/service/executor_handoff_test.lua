local test = require("test")
local registry = require("registry")
local funcs = require("funcs")
local function cases()
    test.describe("Retained launch admission", function()
        test.it("hands the owner's admission to the executor without admitting it again", function()
            local executor = assert(registry.get("bee.harness.service:presentation_executor"))
            executor.id = "bee.tests.harness.service:executor_probe"
            executor.kind = "function.lua"
            executor.data.imports.runtime = "bee.tests.harness.service:runtime_probe"
            executor.data.imports.windows = "bee.tests.harness.service:windows_probe"
            local changes = assert(registry.snapshot()):changes()
            changes:create(executor)
            assert(changes:apply())
            local ok, problem = pcall(function()
                local result, err = funcs.call(executor.id, {}, "session-key", {request_id = "admitted-once"})
                test.is_nil(err, tostring(err))
                test.eq(result, "admitted-once")
            end)
            local cleanup = assert(registry.snapshot()):changes()
            cleanup:delete(executor.id)
            assert(cleanup:apply())
            if not ok then error(tostring(problem)) end
        end)
    end)
end
return test.run_cases(cases)
