-- MIT
local test = require("test")
local tty = require("tty")
local view = require("view")
local appearance = require("appearance")
local function define_tests()
    test.describe("Test Status view", function()
        test.it("clips replay rows and clamps scrolling after resize", function()
            local lines: {string} = {}
            for i = 1, 200 do lines[i] = tostring(i) .. " 日本語 long recorded result" end
            for _, width in ipairs({1, 2, 12, 40, 100}) do
                for _, height in ipairs({1, 5, 8, 20, 40}) do
                    local frame = view.render(width, height, appearance.defaults(), "project", 200, "Last recorded: COMPLETE", lines, 1000, false)
                    test.eq(#frame.rows, height)
                    for _, row in ipairs(frame.rows) do test.eq(tty.text.width(row), width) end
                    test.eq(frame.offset, math.max(0, 200 - math.max(0, height - 7)))
                end
            end
            local first = view.render(60, 20, appearance.defaults(), "project", 200, "History", lines, 0, false)
            local last = view.render(60, 20, appearance.defaults(), "project", 200, "History", lines, 0, true)
            test.eq(first.offset, 0)
            test.eq(last.offset, 187)
            test.is_true(table.concat(first.rows):find("1 日本語", 1, true) ~= nil)
            test.is_true(table.concat(last.rows):find("200 日本語", 1, true) ~= nil)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
