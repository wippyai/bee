local test = require("test")
local registry = require("registry")
local function cases()
    test.describe("Session listing dependencies", function()
        test.it("reads sessions without constructing the launch admission graph", function()
            local seen = {}
            local function visit(id: string)
                if seen[id] then return end
                seen[id] = true
                test.is_false(id == "bee.harness.launch:admission", "session listing loads launch admission")
                local entry = assert(registry.get(id))
                for _, dependency in pairs((entry.data or {}).imports or {}) do visit(dependency) end
            end
            visit("bee.threads.sessions.binding:list")
        end)
    end)
end
return test.run_cases(cases)
