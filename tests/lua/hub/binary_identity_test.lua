-- MIT.
local test = require("test")
local registry = require("registry")
local binary_identity = require("binary_identity")
local limits = require("limits")
local root_pack = require("root_pack")

local function define_tests()
    test.describe("Bee release binary identity", function()
        test.it("reads identity through the same package envelope as planning", function()
            local entries = root_pack.entries()
            for index = #entries + 1, limits.MAX_PACKAGE_ENTRIES do
                entries[index] = {id = "growth:entry_" .. tostring(index), kind = "registry.entry", meta = {}, data = {}}
            end
            local identity, problem = binary_identity.read_packages({{component = "bee/bee", entries = entries}})
            test.is_nil(problem); test.not_nil(identity)
            entries[#entries + 1] = {id = "growth:overflow", kind = "registry.entry", meta = {}, data = {}}
            local oversized, overflow = binary_identity.read_packages({{component = "bee/bee", entries = entries}})
            test.is_nil(oversized)
            test.eq(overflow, "resolved Bee root entries exceeds " .. tostring(limits.MAX_PACKAGE_ENTRIES) .. " items")
        end)
        test.it("decodes the generated root pack entry", function()
            local entry, read_error = registry.get("bee.env:binary_identity")
            test.is_nil(read_error); test.not_nil(entry)
            local identity, problem = binary_identity.read_packages({{component = "bee/bee", entries = {entry}}})
            test.is_nil(problem); test.not_nil(identity)
            if identity then
                test.eq(identity.native, "github.com/wippyai/bee/native")
                test.is_true(identity.runtime_commit:sub(1, 1) == "v")
                test.is_true(#identity.native_components > 0)
            end
        end)
    end)
end

return test.run_cases(define_tests)
