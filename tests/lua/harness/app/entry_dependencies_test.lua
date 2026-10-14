local test = require("test")
local registry = require("registry")
return test.run_cases(function()
    test.describe("Agents entry dependencies", function()
        test.it("routes without constructing the native execution graph", function()
            local seen = {}
            local function visit(id: string)
                if seen[id] then return end
                seen[id] = true
                test.is_false(id == "bee.harness.launch:admission", "Agents directory constructs launch admission")
                test.is_false(id == "bee.harness.app:runtime", "Agents routing constructs the execution loop")
                test.is_false(id == "bee.placement.native.service:window", "Agents routing constructs native windows")
                local entry = assert(registry.get(id))
                for _, dependency in pairs((entry.data or {}).imports or {}) do visit(dependency) end
            end
            visit("bee.harness.app:app")
            visit("bee.harness.app:selection")
        end)
    end)
end)
