-- MIT. Pointer gestures the shared frame recognizes.
local test = require("test")
local frame = require("frame")

local function define_tests()
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
