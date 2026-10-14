-- SPDX-License-Identifier: MIT
local test = require("test")
local registry = require("registry")
return test.run_cases(function()
    test.describe("Launch admission dependencies", function()
        test.it("constructs requests without initializing the carrier machine", function()
            local seen = {}
            local function visit(id: string)
                if seen[id] then return end
                seen[id] = true
                test.is_false(id == "bee.harness.carrier:machine", "admission loads the execution machine")
                local entry = assert(registry.get(id))
                for _, dependency in pairs((entry.data or {}).imports or {}) do visit(dependency) end
            end
            visit("bee.harness.launch:admission")
        end)
    end)
end)
