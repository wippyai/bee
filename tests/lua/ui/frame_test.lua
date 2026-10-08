-- MIT. Pointer gestures the shared frame recognizes.
local test = require("test")
local frame = require("frame")
local appearance = require("appearance")
local tty = require("tty")

local function define_tests()
    test.describe("Application footer", function()
        test.it("keeps complete actions left and hints right on one row", function()
            for _, width in ipairs({24, 40, 80, 120, 160}) do
                local painter = frame.new(width, 12, appearance.defaults())
                local buttons: {frame.Button} = {
                    {kind = "open", key = "Enter", label = "Open", enabled = true, primary = true},
                    {kind = "edit", key = "E", label = "Edit", enabled = true},
                }
                frame.footer(painter, "", "/ search", nil, buttons)
                local rows = frame.rows(painter)
                test.eq(tty.text.width(rows[12]), width)
                test.is_true(rows[12]:find("Enter Open", 1, true) ~= nil)
                test.is_nil(rows[11]:find("Enter Open", 1, true))
                for _, hit in ipairs(painter.hits) do test.eq(hit.y, 12) end
                local plain = rows[12]:gsub("\27%[[0-9;]*m", "")
                test.is_nil(plain:find("…", 1, true))
                if width >= 80 then
                    test.is_true(plain:find("/ search", 1, true) > plain:find("E Edit", 1, true))
                    test.is_true(plain:find("? help", 1, true) ~= nil)
                else test.is_nil(plain:find("/ search", 1, true)) end
            end
        end)
        test.it("shares the footer row with the canonical action geometry", function()
            local layout = frame.layout(frame.new(80, 24, appearance.defaults()), true, true)
            test.eq(layout.actions, layout.footer)
            test.eq(layout.work.y + layout.work.height, layout.footer)
        end)
    end)
    test.describe("Frame gestures", function()
        test.it("treats a second press on the same row within the double-click window as a double click", function()
            local memory = frame.clicks()
            test.is_false(frame.double_click(memory, "choice", 2, 1000))
            test.is_true(frame.double_click(memory, "choice", 2, 1000 + frame.DOUBLE_CLICK_MS))
            test.is_false(frame.double_click(memory, "choice", 2, 1000 + frame.DOUBLE_CLICK_MS + 10))
            test.is_false(frame.double_click(memory, "choice", 3, 5000))
            test.is_false(frame.double_click(memory, "choice", 2, 5010))
            test.is_false(frame.double_click(memory, "session", 2, 9000))
            test.is_false(frame.double_click(memory, "session", 2, 9000 + frame.DOUBLE_CLICK_MS + 1))
        end)
    end)
end

return test.run_cases(define_tests)
