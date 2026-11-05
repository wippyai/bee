-- SPDX-License-Identifier: MIT
local registry = require("registry")
local test = require("test")

local function imports(entry: {data: unknown}): {[string]: unknown}
    local data = entry.data
    if type(data) ~= "table" or type(data.imports) ~= "table" then return {} end
    return data.imports
end

local function define_tests()
    test.describe("Seam binding", function()
        test.it("links every application seam import to the test composition's binding", function()
            local bound, unbound = 0, {}
            for _, entry in ipairs(assert(registry.find({}))) do
                local seam = imports(entry).seam
                if entry.id:find("^bee%.tests%.") then seam = nil end
                if seam == "bee.tests.support:seam" then bound = bound + 1
                elseif seam == "bee.process:seam" then unbound[#unbound + 1] = tostring(entry.id) end
            end
            test.eq(#unbound, 0, "seam imports the bee.process:seams requirement does not target: " .. table.concat(unbound, ", "))
            test.is_true(bound > 0)
        end)
    end)
end

return test.run_cases(define_tests)
