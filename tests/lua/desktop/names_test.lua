local test = require("test")
local names = require("names")

local function define_tests()
    test.describe("Friendly identity labels", function()
        test.it("derives the same label without changing the opaque identity", function()
            local id = "0123456789abcdef0123456789abcdef"
            local first = names.label(id)
            test.eq(names.label(id), first)
            test.is_true(first:find("%S+ %S+") ~= nil)
            test.eq(id, "0123456789abcdef0123456789abcdef")
        end)
        test.it("disambiguates colliding labels in sorted identity order", function()
            local first = "00000000000000000000000000000009"
            local second = "0000000000000000000000000000000a"
            test.eq(names.label(first), names.label(second))
            local labels = names.labels({second, first})
            test.eq(labels[first], names.label(first) .. " 1")
            test.eq(labels[second], names.label(second) .. " 2")
        end)
        test.it("keeps Luna in the friendly vocabulary", function()
            local seen = false
            for index = 0, 4095 do
                local id = string.format("%032x", index)
                if names.label(id):find("Luna", 1, true) then seen = true; break end
            end
            test.is_true(seen)
        end)
    end)
end

return {run = define_tests}
