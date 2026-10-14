local test = require("test")
local registry = require("registry")
return test.run_cases(function()
    test.describe("Application admission catalog dependencies", function()
        test.it("reads catalog revisions without constructing migration execution", function()
            local seen = {}
            local function visit(id: string)
                if seen[id] then return end
                seen[id] = true
                test.is_false(id == "bee.gov.persist:activation_store", "catalog read loads the activation writer")
                test.is_false(id == "bee.gov.binding:preflight", "catalog read loads migration preflight")
                local entry = assert(registry.get(id))
                for _, dependency in pairs((entry.data or {}).imports or {}) do visit(dependency) end
            end
            visit("bee.gov.binding:application_admissions")
        end)
    end)
end)
