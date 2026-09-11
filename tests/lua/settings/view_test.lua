local test = require("test")
local tty = require("tty")
local view = require("view")
local appearance = require("appearance")
local function define_tests()
    test.describe("Appearance chooser", function()
        test.it("shows errors in compact settings without losing selection controls", function()
            local frame = view.draw(28, 6, appearance.defaults(), "theme", 0, "Permission denied")
            test.is_true(table.concat(frame.rows, "\n"):find("Permission denied", 1, true) ~= nil)
            local steps = 0
            for _, hit in ipairs(frame.hits) do if hit.kind == "step" then steps = steps + 1 end end
            test.eq(steps, 2)
            for _, row in ipairs(frame.rows) do test.eq(tty.text.width(row), 28) end
        end)
        test.it("keeps cards, tabs and hits inside every terminal size", function()
            for _, width in ipairs({1, 12, 18, 28, 47, 48, 49, 62, 100}) do
                for _, height in ipairs({1, 8, 18, 30}) do
                    for _, pane in ipairs({"theme", "background", "taskbar"}) do
                        local frame = view.draw(width, height, appearance.defaults(), pane == "theme" and "theme" or (pane == "background" and "background" or "taskbar"), 0)
                        test.eq(#frame.rows, height)
                        for _, row in ipairs(frame.rows) do test.eq(tty.text.width(row), width) end
                        for _, hit in ipairs(frame.hits) do
                            test.is_true(hit.x >= 1 and hit.y >= 1)
                            test.is_true(hit.x + hit.width - 1 <= width)
                            test.is_true(hit.y + hit.height - 1 <= height)
                            test.is_true(view.hit(frame.hits, hit.x, hit.y) ~= nil)
                        end
                        test.is_nil(view.hit(frame.hits, width + 1, 1))
                    end
                end
            end
        end)
        test.it("allows browsing past the selection and reveals it only on request", function()
            local grid = view.grid(62, 18)
            test.eq(grid.columns, 2)
            test.eq(grid.capacity, 4)
            test.eq(view.offset(1, 2, grid, 14, false), 2)
            test.eq(view.offset(1, 2, grid, 14, true), 0)
            local end_offset = view.offset(14, 0, grid, 14, true)
            test.is_true(14 > end_offset and 14 <= end_offset + grid.capacity)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
